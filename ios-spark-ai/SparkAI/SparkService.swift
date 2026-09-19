//
//  SparkService.swift
//  SparkAI
//
//  Self-hosted chat route for the DGX Spark (GB10) vLLM server serving the
//  user's abliterated fine-tune in NVFP4 (e.g. Qwen3.6-35B-A3B Abliterated
//  NVFP4+MTP) via vLLM's OpenAI-compatible API on :8000. Thinking is
//  disabled at the chat-template level by default (aiui parity), and when
//  Agent Mode is on the route advertises the full live-tool set natively
//  (OpenAI `tools` with streamed `tool_calls`), unlocking parallel multi-hop
//  tool execution on-device.
//
//  Route priority: Edge0 → Spark vLLM NVFP4 → Featherless → Rork cloud →
//  local simulated GB10.
//

import Foundation

nonisolated struct SparkConfig: Codable, Equatable {
    var isEnabled: Bool = false
    var host: String = "192.168.4.103"
    var port: Int = 8000
    var model: String = "qwen-abliterated"
    var apiKey: String = ""
    /// Sends `chat_template_kwargs: {enable_thinking: false}` so the
    /// abliterated fine-tune answers directly instead of streaming a
    /// thinking trace first.
    var disableThinking: Bool = true

    var isValid: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && (80...65535).contains(port)
    }

    var resolvedModel: String {
        let trimmed = model.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "qwen-abliterated" : trimmed
    }
}

nonisolated struct ServedModel: Identifiable, Equatable, Sendable {
    let id: String

    var shortName: String {
        id.split(separator: "/").last.map(String.init) ?? id
    }
}

nonisolated final class SparkService {
    private static let configKey = "spark-vllm-config"

    private static let systemPrompt = """
    You are Spark AI, the assistant inside a DGX Spark (GB10) mesh console. \
    You are technical, precise and concise — comfortable with GPU architecture, \
    model serving (vLLM), image diffusion and Python tooling. Use markdown with \
    fenced code blocks where useful. Keep answers tight and actionable.
    """

    private(set) var config: SparkConfig

    var isConfigured: Bool { config.isEnabled && config.isValid }

    init() {
        config = PersistenceStore.load(SparkConfig.self, forKey: Self.configKey) ?? SparkConfig()
    }

    /// Persists an updated connection config.
    func update(_ config: SparkConfig) {
        self.config = config
        PersistenceStore.save(config, forKey: Self.configKey)
    }

    /// Lists the models currently served by the local vLLM instance.
    func fetchModels() async throws -> [ServedModel] {
        guard let url = Self.makeURL(host: config.host, port: config.port, path: "/v1/models") else {
            throw CloudInferenceError.missingConfiguration
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudInferenceError.serverError(-1)
        }
        switch http.statusCode {
        case 200: break
        case 401: throw CloudInferenceError.authError
        case 429: throw CloudInferenceError.rateLimited
        default: throw CloudInferenceError.serverError(http.statusCode)
        }

        struct Catalog: Decodable {
            struct Entry: Decodable { let id: String }
            let data: [Entry]
        }
        return try JSONDecoder().decode(Catalog.self, from: data).data.map { ServedModel(id: $0.id) }
    }

    /// Streams a chat completion, emitting reasoning/content deltas plus
    /// native `tool_calls` fragments as they arrive. `systemPrompt` overrides
    /// the built-in persona (Agent Mode); `enableTools` advertises the live
    /// tool set via the OpenAI function-calling protocol.
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
            "messages": OpenAIMessages.makeMessages(from: history, systemPrompt: promptOverride ?? Self.systemPrompt),
        ]
        if config.disableThinking {
            payload["chat_template_kwargs"] = ["enable_thinking": false]
        }
        if enableTools {
            payload["tools"] = AgentService.toolsPayload()
            payload["tool_choice"] = "auto"
        }

        // vLLM serves the OpenAI API under /v1; retry the bare path for
        // servers rooted at "/".
        let paths = ["/v1/chat/completions", "/chat/completions"]
        var stream: URLSession.AsyncBytes?
        var lastStatus = -1

        for path in paths {
            guard let url = Self.makeURL(host: config.host, port: config.port, path: path) else {
                throw CloudInferenceError.missingConfiguration
            }

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

    private static func makeURL(host rawHost: String, port: Int, path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = sanitizeHost(rawHost)
        components.port = port
        components.path = path
        return components.url
    }

    /// Accepts hosts typed as `192.168.4.103`, `mybox.local` or full URLs and
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
