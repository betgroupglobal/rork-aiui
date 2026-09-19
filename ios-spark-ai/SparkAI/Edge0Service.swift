//
//  Edge0Service.swift
//  SparkAI
//
//  Self-hosted chat route for Edge0-35B-A3B-preview
//  (https://huggingface.co/Edge0/Edge0-35B-A3B-preview) — a Qwen3.5-MoE
//  35B-A3B edge model served by the `edge0 serve` OpenAI-compatible HTTP API
//  on the user's own workstation. When enabled it becomes the primary chat
//  route, falling back to Featherless → Rork cloud → local GB10 simulation.
//

import Foundation

/// User-configurable connection to a self-hosted `edge0 serve` endpoint.
nonisolated struct Edge0Config: Codable, Equatable {
    var isEnabled: Bool = false
    var host: String = "192.168.1.44"
    var port: Int = 8085
    var model: String = "edge0-35b"
    var apiKey: String = ""

    var isValid: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && (80...65535).contains(port)
    }

    var resolvedModel: String {
        let trimmed = model.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "edge0-35b" : trimmed
    }
}

nonisolated final class Edge0Service {
    private static let configKey = "edge0-config"

    private let systemPrompt = """
    You are Spark AI, the assistant inside a DGX Spark (GB10) mesh console. \
    You are technical, precise and concise — comfortable with GPU architecture, \
    model serving (vLLM), image diffusion and Python tooling. Use markdown with \
    fenced code blocks where useful. Keep answers tight and actionable.
    """

    private(set) var config: Edge0Config

    var isConfigured: Bool { config.isEnabled && config.isValid }

    init() {
        config = PersistenceStore.load(Edge0Config.self, forKey: Self.configKey) ?? Edge0Config()
    }

    /// Persists an updated connection config.
    func update(_ config: Edge0Config) {
        self.config = config
        PersistenceStore.save(config, forKey: Self.configKey)
    }

    /// Streams a chat completion, emitting reasoning/content deltas as they
    /// arrive. `systemPrompt` overrides the built-in persona (Agent Mode);
    /// `enableTools` advertises the live tool set via the OpenAI
    /// function-calling protocol (native tool_calls streaming).
    func stream(history: [ChatTurn], systemPrompt: String? = nil, enableTools: Bool = false) -> AsyncThrowingStream<CloudStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(history: history, promptOverride: systemPrompt, enableTools: enableTools, continuation: continuation)
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(history: [ChatTurn], promptOverride: String?, enableTools: Bool, continuation: AsyncThrowingStream<CloudStreamEvent, Error>.Continuation) async throws {
        guard isConfigured else { throw CloudInferenceError.missingConfiguration }

        var payload: [String: Any] = [
            "model": config.resolvedModel,
            "stream": true,
            "temperature": 0.7,
            "max_tokens": 2048,
            "messages": OpenAIMessages.makeMessages(from: history, systemPrompt: promptOverride ?? systemPrompt),
        ]
        if enableTools {
            payload["tools"] = AgentService.toolsPayload()
            payload["tool_choice"] = "auto"
        }

        // `edge0 serve` documents an OpenAI-compatible API; try the /v1 mount
        // first and fall back to the bare path for servers rooted at "/".
        let paths = ["/v1/chat/completions", "/chat/completions"]
        var stream: URLSession.AsyncBytes?
        var lastStatus = -1

        for path in paths {
            var components = URLComponents()
            components.scheme = "http"
            components.host = Self.sanitizeHost(config.host)
            components.port = config.port
            components.path = path
            guard let url = components.url else { throw CloudInferenceError.missingConfiguration }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 120
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !config.apiKey.isEmpty {
                request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            lastStatus = status

            if status == 200 {
                stream = bytes
                break
            }
            // Only the 404 mount probe is retryable; everything else is fatal.
            guard status == 404 else {
                switch status {
                case 401: throw CloudInferenceError.authError
                case 429: throw CloudInferenceError.rateLimited
                default: throw CloudInferenceError.serverError(status)
                }
            }
        }

        guard let bytes = stream else { throw CloudInferenceError.serverError(lastStatus) }

        for try await line in bytes.lines {
            if Task.isCancelled { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data: ") else { continue }
            let json = String(trimmed.dropFirst(6))
            guard !json.isEmpty, json != "[DONE]" else { continue }

            guard let data = json.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
                  let delta = chunk.choices.first?.delta else { continue }

            if let reasoning = delta.reasoning ?? delta.reasoningContent, !reasoning.isEmpty {
                continuation.yield(.reasoning(reasoning))
            }
            if let content = delta.content, !content.isEmpty {
                continuation.yield(.content(content))
            }
            if let fragments = delta.toolCalls, !fragments.isEmpty {
                continuation.yield(.toolCalls(fragments))
            }
        }
        continuation.finish()
    }

    /// Accepts hosts typed as `192.168.1.44`, `mybox.local` or full URLs and
    /// strips scheme/port/path so URLComponents stays valid.
    private static func sanitizeHost(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespaces)
        for prefix in ["http://", "https://"] where host.lowercased().hasPrefix(prefix) {
            host = String(host.dropFirst(prefix.count))
        }
        if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
        if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
        return host
    }
}
