//
//  OpenAIStreamSupport.swift
//  SparkAI
//
//  Shared OpenAI-compatible tool-calling plumbing for the self-hosted routes
//  (Spark vLLM NVFP4, Edge0 serve): streamed `tool_calls` delta fragments, an
//  index-based assembler that reassembles them into complete calls, and
//  message serialization for native multi-turn tool calling.
//

import Foundation

/// A streamed `delta.tool_calls` fragment — pieces of one or more function
/// calls split across many SSE chunks (id/name first, argument JSON in
/// pieces after).
nonisolated struct ToolCallFragment: Decodable, Sendable {
    let index: Int
    let id: String?
    let type: String?
    let function: FunctionFragment?

    nonisolated struct FunctionFragment: Decodable, Sendable {
        let name: String?
        let arguments: String?
    }
}

/// A complete native tool call, reassembled from streamed fragments.
nonisolated struct NativeToolCall: Equatable, Sendable {
    let id: String
    let name: String
    let arguments: String
}

/// Accumulates streamed tool_calls fragments keyed by their `index` so a
/// route can hand complete calls to the agent loop when the stream ends.
nonisolated struct ToolCallAssembler {
    private var ids: [Int: String] = [:]
    private var names: [Int: String] = [:]
    private var arguments: [Int: String] = [:]

    mutating func absorb(_ fragments: [ToolCallFragment]) {
        for fragment in fragments {
            if let id = fragment.id, !id.isEmpty { ids[fragment.index] = id }
            if let name = fragment.function?.name, !name.isEmpty {
                names[fragment.index, default: ""] += name
            }
            if let arguments = fragment.function?.arguments {
                self.arguments[fragment.index, default: ""] += arguments
            }
        }
    }

    /// Complete calls in stream order; fragments without a resolvable name
    /// are dropped.
    var calls: [NativeToolCall] {
        Set(ids.keys).union(names.keys).union(arguments.keys)
            .sorted()
            .compactMap { index in
                guard let name = names[index], !name.isEmpty else { return nil }
                return NativeToolCall(
                    id: ids[index] ?? "call_\(index)",
                    name: name,
                    arguments: arguments[index] ?? "{}"
                )
            }
    }

    var hasCalls: Bool { !names.isEmpty }
}

/// Builds OpenAI chat `messages` from the app's transcript turns, mapping
/// assistant tool-call turns and `role:"tool"` results to the wire format
/// vLLM and edge0 serve expect for multi-turn tool calling.
nonisolated enum OpenAIMessages {
    static func makeMessages(from history: [ChatTurn], systemPrompt: String?) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        if let systemPrompt, !systemPrompt.isEmpty {
            messages.append(["role": "system", "content": systemPrompt])
        }
        for turn in history {
            if turn.role == "tool", !turn.toolCallID.isEmpty {
                messages.append([
                    "role": "tool",
                    "tool_call_id": turn.toolCallID,
                    "content": turn.content,
                ])
            } else if !turn.toolCalls.isEmpty {
                messages.append([
                    "role": "assistant",
                    "content": turn.content,
                    "tool_calls": turn.toolCalls.map { call in
                        [
                            "id": call.id,
                            "type": "function",
                            "function": [
                                "name": call.name,
                                "arguments": call.arguments.isEmpty ? "{}" : call.arguments,
                            ] as [String: Any],
                        ] as [String: Any]
                    },
                ])
            } else {
                messages.append(["role": turn.role, "content": turn.content])
            }
        }
        return messages
    }
}
