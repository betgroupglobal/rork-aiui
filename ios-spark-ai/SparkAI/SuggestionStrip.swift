//
//  SuggestionStrip.swift
//  SparkAI
//

import SwiftUI

struct SuggestionStrip: View {
    let onSelect: (String) -> Void
    var disabled = false

    private let prompts: [(icon: String, label: String, prompt: String, tint: Color)] = [
        ("testtube.2", "Pytest Sandbox", "Write a Python module for token bucket rate limiting with an accompanying test_ratelimit.py pytest suite ready for sandbox execution.", Theme.emerald),
        ("cpu", "GB10 Specs", "Summarize the architecture and specs of NVIDIA DGX Spark GB10 Blackwell.", Theme.amber),
        ("bolt.horizontal", "Async vLLM Client", "Write an ultra-fast streaming Python async client for our local DGX Spark vLLM server.", Theme.sky),
        ("chevron.left.forwardslash.chevron.right", "Code Gen", "Show an optimized React Native component using clean state.", Theme.blue),
        ("point.3.connected.trianglepath.dotted", "System Topology", "Explain the local mesh topology: ports 8000, 7860, 8188, and 17325.", Theme.rose),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(prompts.enumerated()), id: \.offset) { index, item in
                    Button {
                        onSelect(item.prompt)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: item.icon)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(item.tint)
                            Text(item.label)
                                .font(Theme.display(12.5, .semibold))
                                .foregroundStyle(Theme.textPrimary)
                        }
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .background(Theme.bgSurface.opacity(0.9), in: .capsule)
                        .overlay(Capsule().strokeBorder(item.tint.opacity(0.28)))
                        .shadow(color: item.tint.opacity(0.12), radius: 10, y: 3)
                    }
                    .buttonStyle(.pressable)
                    .disabled(disabled)
                    .opacity(disabled ? 0.4 : 1)
                    .entrance(delay: 0.35 + Double(index) * 0.07, offset: 10)
                }
            }
            .padding(.horizontal, 14)
        }
        .padding(.vertical, 6)
    }
}

#Preview {
    SuggestionStrip(onSelect: { _ in })
        .background(Theme.bgPrimary)
}
