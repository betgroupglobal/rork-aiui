//
//  ChatEngine.swift
//  SparkAI
//
//  Local simulated inference engine for the GB10 assistant. Keyword-matched
//  canned responses with reasoning traces, structured so a real
//  OpenAI-compatible endpoint can be plugged in later.
//

import Foundation

struct EngineReply {
    let reasoning: String?
    let content: String
}

@MainActor
final class ChatEngine {
    private let prompts: [String: EngineReply] = [
        "gb10": EngineReply(
            reasoning: "User asked about the DGX Spark GB10. Pulling architecture summary: Blackwell GPU + 20-core Grace CPU, coherent LPDDR5x memory, FP4 tensor core support. Keep it structured and concise.",
            content: """
            **NVIDIA DGX Spark (GB10) — Architecture Summary**

            - **Compute:** Blackwell GPU with 5th-gen Tensor Cores + 20-core Arm Grace CPU, tightly coupled over NVLink-C2C.
            - **Memory:** 128 GB coherent unified LPDDR5x, ~273 GB/s bandwidth — CUDA sees it as one address space.
            - **Precision:** Native FP4 / NVFP4 acceleration for inference; the entire memory pool is CUDA-visible.
            - **Networking:** ConnectX-7 for 200 GbE clustering of two Spark units with RDMA.

            Perfect target for local abliterated model serving — fits 70B-class quantized models entirely in unified memory.
            """
        ),
        "vllm": EngineReply(
            reasoning: "User wants a fast streaming async client for the local vLLM server on port 8000. Provide a compact Python client using httpx SSE streaming against the OpenAI-compatible /v1/chat/completions endpoint.",
            content: """
            Here's a lean async streaming client for the Spark vLLM endpoint:

            ```python
            import asyncio, httpx, json

            BASE = "http://localhost:8000/v1"

            async def stream_chat(messages: list[dict], model: str):
                async with httpx.AsyncClient(timeout=None) as client:
                    async with client.stream(
                        "POST", f"{BASE}/chat/completions",
                        json={"model": model, "messages": messages, "stream": True},
                    ) as response:
                        async for line in response.aiter_lines():
                            if not line.startswith("data: "):
                                continue
                            payload = line.removeprefix("data: ")
                            if payload == "[DONE]":
                                break
                            delta = json.loads(payload)["choices"][0]["delta"]
                            if chunk := delta.get("content"):
                                print(chunk, end="", flush=True)

            asyncio.run(stream_chat(
                [{"role": "user", "content": "Explain NVFP4 quantization."}],
                model="abliterated-70b",
            ))
            ```

            Key details: `timeout=None` keeps the SSE connection alive for long generations, and the walrus operator skips empty deltas cleanly.
            """
        ),
        "pytest": EngineReply(
            reasoning: "Sandbox task: token bucket rate limiter plus pytest suite. Design: capacity + refill_rate, refill lazily on each acquire based on elapsed time. Tests cover initial burst, refill over time, and exhaustion. Ready for sandbox execution.",
            content: """
            Here's the module and test suite, ready for the sandbox runner:

            ```python
            # ratelimit.py
            import time

            class TokenBucket:
                def __init__(self, capacity: float, refill_rate: float):
                    self.capacity = capacity
                    self.refill_rate = refill_rate
                    self.tokens = capacity
                    self.updated = time.monotonic()

                def _refill(self) -> None:
                    now = time.monotonic()
                    self.tokens = min(
                        self.capacity,
                        self.tokens + (now - self.updated) * self.refill_rate,
                    )
                    self.updated = now

                def acquire(self, amount: float = 1.0) -> bool:
                    self._refill()
                    if self.tokens >= amount:
                        self.tokens -= amount
                        return True
                    return False
            ```

            ```python
            # test_ratelimit.py
            from ratelimit import TokenBucket

            def test_initial_burst():
                bucket = TokenBucket(capacity=3, refill_rate=1.0)
                assert all(bucket.acquire() for _ in range(3))
                assert not bucket.acquire()

            def test_refill_over_time():
                bucket = TokenBucket(capacity=1, refill_rate=10.0)
                assert bucket.acquire()
                time.sleep(0.15)
                assert bucket.acquire()
            ```

            Both tests are deterministic; drop them in the sandbox environment and run `pytest -q`.
            """
        ),
        "topology": EngineReply(
            reasoning: "User asked about the local mesh topology and the service ports. Map: 8000 vLLM inference, 7860 Krea/Gradio image, 8188 ComfyUI, 17325 RAG service. Explain the failover chain briefly.",
            content: """
            **Local Mesh Topology**

            | Port | Service | Role |
            |------|---------|------|
            | 8000 | vLLM | OpenAI-compatible inference, SSE streaming |
            | 7860 | Krea / Gradio | Image generation endpoint |
            | 8188 | ComfyUI | Graph-based diffusion workflows |
            | 17325 | RAG Service | Retrieval + grounding citations |

            Route selection is zero-config: direct LAN wins on latency, Tailscale provides the roaming fallback, and the public cloud mirror absorbs overflow. Probing happens automatically on the Telemetry tab.
            """
        ),
    ]

    private let fallbacks: [String] = [
        "On it. The request is routed through the local GB10 stack — vLLM is serving the abliterated weights from unified memory, so response latency is bounded by token throughput rather than network. Let me know if you want me to spin up the sandbox runner or pull RAG citations for grounding.",
        "Understood. I've dispatched this to the session environment. Nothing here leaves the LAN — inference runs locally on the Blackwell tensor cores, and any generated artifacts land in the workspace files. Want me to queue a test run against it?",
    ]

    /// Streams a reply chunk-by-chunk for the given user message.
    /// - Parameter text: the user's message
    /// - Returns: an async sequence of small string chunks
    func streamReply(for text: String) -> AsyncThrowingStream<String, Error> {
        let reply = reply(for: text)
        let full = reply.content
        return AsyncThrowingStream { continuation in
            let task = Task {
                var index = full.startIndex
                while index < full.endIndex {
                    if Task.isCancelled { break }
                    let chunkSize = Int.random(in: 2...7)
                    let endIndex = full.index(index, offsetBy: chunkSize, limitedBy: full.endIndex) ?? full.endIndex
                    continuation.yield(String(full[index..<endIndex]))
                    index = endIndex
                    try? await Task.sleep(for: .milliseconds(Int.random(in: 14...38)))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func reply(for text: String) -> EngineReply {
        let lowered = text.lowercased()

        for (keyword, reply) in prompts where lowered.contains(keyword) {
            return reply
        }

        if lowered.contains("react") || lowered.contains("component") {
            return EngineReply(
                reasoning: "Code generation request. Provide a clean RN component example with hooks and no unnecessary re-renders.",
                content: """
                Here's an optimized component pattern:

                ```tsx
                import { memo, useCallback, useState } from "react";
                import { Pressable, StyleSheet, Text } from "react-native";

                interface Props {
                  title: string;
                  onSelect: (id: string) => void;
                }

                const Row = memo(({ title, onSelect }: Props) => {
                  const handlePress = useCallback(() => onSelect(title), [onSelect, title]);
                  return (
                    <Pressable style={({ pressed }) => [styles.row, pressed && styles.pressed]} onPress={handlePress}>
                      <Text style={styles.label}>{title}</Text>
                    </Pressable>
                  );
                });
                ```

                Memoized rows plus stable callbacks keep the list flat at 60 fps even with hundreds of entries.
                """
            )
        }

        return EngineReply(reasoning: nil, content: fallbacks.randomElement() ?? fallbacks[0])
    }
}
