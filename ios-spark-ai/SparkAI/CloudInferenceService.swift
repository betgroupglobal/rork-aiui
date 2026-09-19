//
//  CloudInferenceService.swift
//  SparkAI
//
//  Cloud-routed inference through the Rork AI proxy (OpenAI-compatible).
//  Streams SSE chat completions — including live reasoning deltas — and is
//  used as the primary chat route, with the local simulated GB10 engine as
//  the offline fallback.
//

import Foundation

enum CloudStreamEvent {
    case reasoning(String)
    case content(String)
    /// Streamed `tool_calls` fragments from native tool-calling routes
    /// (Spark vLLM NVFP4, Edge0 serve).
    case toolCalls([ToolCallFragment])
}

enum CloudInferenceError: LocalizedError {
    case missingConfiguration
    case authError
    case quotaExceeded
    case rateLimited
    case payloadTooLarge
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration: "Cloud inference is not configured."
        case .authError: "AI features are currently unavailable. Please restart the app."
        case .quotaExceeded: "AI features are temporarily unavailable. Please try again later."
        case .rateLimited: "Too many requests. Please wait a moment and try again."
        case .payloadTooLarge: "That media is too large to send. Try a smaller source."
        case .serverError: "Something went wrong. Please try again."
        }
    }
}

nonisolated struct ChatTurn: Sendable {
    let role: String
    let content: String
    /// Native tool calls requested by the assistant in this turn (advanced
    /// tool calling). Serialized as an OpenAI assistant `tool_calls` message.
    var toolCalls: [NativeToolCall] = []
    /// tool_call id for `role == "tool"` result turns.
    var toolCallID: String = ""
}

nonisolated final class CloudInferenceService {
    static let modelID = "inclusionai/ling-3.0-flash-vl-free"

    private static let systemPrompt = """
    You are Spark AI, the assistant inside a DGX Spark (GB10) mesh console. \
    You are technical, precise and concise — comfortable with GPU architecture, \
    model serving (vLLM), image diffusion and Python tooling. Use markdown with \
    fenced code blocks where useful. Keep answers tight and actionable.
    """

    private let toolkitURL: String
    private let secretKey: String

    var isConfigured: Bool {
        !toolkitURL.isEmpty && !secretKey.isEmpty
    }

    init() {
        toolkitURL = Config.EXPO_PUBLIC_TOOLKIT_URL
        secretKey = Config.EXPO_PUBLIC_RORK_TOOLKIT_SECRET_KEY
    }

    /// Streams a completion for the given conversation, emitting reasoning
    /// and content deltas as they arrive from the gateway. `systemPrompt`
    /// overrides the built-in persona (used by Agent Mode).
    func stream(history: [ChatTurn], systemPrompt: String? = nil) -> AsyncThrowingStream<CloudStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(history: history, systemPrompt: systemPrompt, continuation: continuation)
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(history: [ChatTurn], systemPrompt: String?, continuation: AsyncThrowingStream<CloudStreamEvent, Error>.Continuation) async throws {
        guard let url = URL(string: "\(toolkitURL)/v2/vercel/v1/chat/completions"), isConfigured else {
            throw CloudInferenceError.missingConfiguration
        }

        var payload: [String: Any] = [
            "model": Self.modelID,
            "stream": true,
            "temperature": 0.7,
            "max_tokens": 2048,
            "messages": [["role": "system", "content": systemPrompt ?? Self.systemPrompt]]
                + history.map { ["role": $0.role, "content": $0.content] },
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(secretKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudInferenceError.serverError(-1)
        }
        switch http.statusCode {
        case 200: break
        case 401: throw CloudInferenceError.authError
        case 402: throw CloudInferenceError.quotaExceeded
        case 429: throw CloudInferenceError.rateLimited
        default: throw CloudInferenceError.serverError(http.statusCode)
        }

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
        }
        continuation.finish()
    }
}

// Shared SSE delta decoder used by all OpenAI-compatible routes.
nonisolated struct StreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
            let reasoning: String?
            let reasoningContent: String?
            let toolCalls: [ToolCallFragment]?

            enum CodingKeys: String, CodingKey {
                case content, reasoning, toolCalls
                case reasoningContent = "reasoning_content"
            }
        }
        let delta: Delta
    }
    let choices: [Choice]
}
