//
//  FeatherlessService.swift
//  SparkAI
//
//  Serverless inference through the Featherless API (OpenAI-compatible) —
//  the primary chat route, serving abliterated open-weight models with
//  live catalog discovery and SSE streaming.
//

import Foundation

nonisolated struct FeatherlessModel: Identifiable, Decodable, Equatable {
    let id: String
    let contextLength: Int
    let maxCompletionTokens: Int

    enum CodingKeys: String, CodingKey {
        case id
        case contextLength = "context_length"
        case maxCompletionTokens = "max_completion_tokens"
    }

    var shortName: String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    var isAbliterated: Bool {
        let lowered = id.lowercased()
        return lowered.contains("abliterat")
            || lowered.contains("uncensor")
            || lowered.contains("unhinged")
            || lowered.contains("unfiltered")
    }
}

nonisolated struct ModelCatalog: Decodable {
    let data: [FeatherlessModel]
}

nonisolated final class FeatherlessService {
    static let baseURL = "https://api.featherless.ai/v1"

    private static let systemPrompt = """
    You are Spark AI, the assistant inside a DGX Spark (GB10) mesh console. \
    You are technical, precise and concise — comfortable with GPU architecture, \
    model serving (vLLM), image diffusion and Python tooling. Use markdown with \
    fenced code blocks where useful. Keep answers tight and actionable.
    """

    private let apiKey: String
    private let envModel: String

    var isConfigured: Bool { !apiKey.isEmpty }

    init() {
        apiKey = Config.EXPO_PUBLIC_FEATHERLESS_API_KEY
        envModel = Config.EXPO_PUBLIC_FEATHERLESS_MODEL
    }

    /// Explicit model override from the environment, if set.
    func envDefaultModelID() -> String? {
        envModel.isEmpty ? nil : envModel
    }

    /// Fetches the live model catalog from the Featherless API.
    func fetchModels() async throws -> [FeatherlessModel] {
        guard let url = URL(string: "\(Self.baseURL)/models"), isConfigured else {
            throw CloudInferenceError.missingConfiguration
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("Spark AI", forHTTPHeaderField: "X-Title")

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

        return try JSONDecoder().decode(ModelCatalog.self, from: data).data
    }

    /// Picks the best abliterated model from the catalog: instruct-tuned
    /// first, then the largest usable context. Falls back to any capable
    /// model so the route never dead-ends.
    func resolveDefaultModelID(from models: [FeatherlessModel]) -> String? {
        let capable = models.filter { $0.contextLength >= 8192 }
        let abliterated = capable.filter(\.isAbliterated)
        let pool = abliterated.isEmpty ? capable : abliterated

        return pool
            .sorted { lhs, rhs in
                let lhsInstruct = lhs.id.lowercased().contains("instruct")
                let rhsInstruct = rhs.id.lowercased().contains("instruct")
                if lhsInstruct != rhsInstruct { return lhsInstruct }
                if lhs.maxCompletionTokens != rhs.maxCompletionTokens {
                    return lhs.maxCompletionTokens > rhs.maxCompletionTokens
                }
                return lhs.contextLength > rhs.contextLength
            }
            .first?.id
    }

    /// Streams a chat completion for the given conversation and model,
    /// emitting reasoning/content deltas as they arrive. `systemPrompt`
    /// overrides the built-in persona (used by Agent Mode).
    func stream(history: [ChatTurn], model: String, systemPrompt: String? = nil) -> AsyncThrowingStream<CloudStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(history: history, model: model, systemPrompt: systemPrompt, continuation: continuation)
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(history: [ChatTurn], model: String, systemPrompt: String?, continuation: AsyncThrowingStream<CloudStreamEvent, Error>.Continuation) async throws {
        guard let url = URL(string: "\(Self.baseURL)/chat/completions"), isConfigured else {
            throw CloudInferenceError.missingConfiguration
        }

        let payload: [String: Any] = [
            "model": model,
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
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("Spark AI", forHTTPHeaderField: "X-Title")
        request.setValue("https://rork.app", forHTTPHeaderField: "HTTP-Referer")
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
