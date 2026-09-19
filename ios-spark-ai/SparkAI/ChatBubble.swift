//
//  ChatBubble.swift
//  SparkAI
//

import SwiftUI

struct ChatBubble: View {
    let message: ChatMessage
    var onRunInBash: ((String) -> Void)?

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if message.role == .user { Spacer(minLength: 48) }
            bubble
            if message.role == .assistant { Spacer(minLength: 24) }
        }
    }

    @ViewBuilder
    private var bubble: some View {
        if message.role == .user {
            Text(message.content)
                .font(.system(size: 14.5))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(
                        colors: [Theme.sky.opacity(0.95), Theme.blue],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    in: UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 6, topTrailingRadius: 18, style: .continuous)
                )
                .shadow(color: Theme.blue.opacity(0.3), radius: 12, y: 4)
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = message.content
                        Haptics.light()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let shell = message.shellResult {
                    ShellResultCard(result: shell)
                } else if let tool = message.toolRun {
                    AgentToolCard(run: tool)
                } else {
                    if let reasoning = message.reasoning {
                        ReasoningDisclosure(text: reasoning)
                    }
                    MessageContent(text: message.content, isStreaming: message.isStreaming, onRunInBash: onRunInBash)
                    if !message.isStreaming, !message.content.isEmpty {
                        speakButton
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bgSurface.opacity(0.92), in: UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 18, bottomTrailingRadius: 18, topTrailingRadius: 18, style: .continuous))
            .overlay(
                UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 18, bottomTrailingRadius: 18, topTrailingRadius: 18, style: .continuous)
                    .strokeBorder(message.isStreaming ? Theme.sky.opacity(0.35) : Theme.border)
            )
            .animation(Theme.snap, value: message.isStreaming)
            .contextMenu {
                if !message.content.isEmpty {
                    Button {
                        UIPasteboard.general.string = message.content
                        Haptics.light()
                    } label: {
                        Label("Copy reply", systemImage: "doc.on.doc")
                    }
                }
            }
        }
    }
    private var isSpeakingThis: Bool {
        SpeechSynthesisService.shared.speakingMessageID == message.id
    }

    private var speakButton: some View {
        HStack(spacing: 5) {
            Button {
                Haptics.light()
                SpeechSynthesisService.shared.toggle(for: message.id, rawText: message.content)
            } label: {
                Image(systemName: isSpeakingThis ? "speaker.wave.2.fill" : "speaker.wave.2")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSpeakingThis ? Theme.sky : Theme.textTertiary)
            }
            .buttonStyle(.plain)
            Text(isSpeakingThis ? "Reading aloud" : "Listen")
                .font(Theme.mono(10, .semibold))
                .foregroundStyle(isSpeakingThis ? Theme.sky : Theme.textTertiary)
            Spacer()
        }
    }
}

// MARK: - Reasoning trace

private struct ReasoningDisclosure: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(Theme.snap) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Reasoning")
                        .font(.system(size: 11, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .foregroundStyle(Theme.sky)
            }
            .buttonStyle(.pressable(scale: 0.97))

            if isExpanded {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(10)
                    .background(Theme.skyDim, in: .rect(cornerRadius: 10))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(Theme.bgElevated, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.sky.opacity(0.18)))
    }
}

// MARK: - Content rendering with code blocks

private struct MessageContent: View {
    let text: String
    let isStreaming: Bool
    var onRunInBash: ((String) -> Void)?

    private var segments: [Segment] {
        Segment.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                if segment.isCode {
                    CodeBlock(code: segment.text, onRun: onRunInBash)
                } else if !segment.text.isEmpty {
                    ProseText(text: segment.text)
                }
            }
            if isStreaming {
                StreamingCaret()
            }
        }
    }
}

private struct ProseText: View {
    let text: String

    var body: some View {
        Text(attributed)
            .font(.system(size: 14.5))
            .foregroundStyle(Theme.textPrimary)
            .lineSpacing(4)
            .tint(Theme.sky)
    }

    /// Inline markdown (bold, italic, code, links) via AttributedString;
    /// falls back to plain text when parsing fails.
    private var attributed: AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

private struct CodeBlock: View {
    let code: String
    var onRun: ((String) -> Void)?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("CODE")
                    .font(Theme.mono(9, .heavy))
                    .tracking(1)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                if let onRun {
                    Button {
                        Haptics.medium()
                        onRun(code)
                    } label: {
                        Label("RUN", systemImage: "bolt.fill")
                            .labelStyle(.titleAndIcon)
                            .font(Theme.mono(9, .heavy))
                            .tracking(0.8)
                            .foregroundStyle(Theme.emerald)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Theme.emeraldDim, in: .capsule)
                            .overlay(Capsule().strokeBorder(Theme.emerald.opacity(0.35)))
                    }
                    .buttonStyle(.pressable(haptic: false))
                }
                Button {
                    UIPasteboard.general.string = code
                    Haptics.success()
                    withAnimation(Theme.snap) { copied = true }
                    Task {
                        try? await Task.sleep(for: .seconds(1.4))
                        withAnimation(Theme.snap) { copied = false }
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(copied ? Theme.emerald : Theme.textTertiary)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.pressable(haptic: false))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Color(hex: 0xE4E4E7))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .background(Color(hex: 0x0C0C10), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }
}

private struct StreamingCaret: View {
    @State private var visible = true

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(Theme.spark)
                    .frame(width: 5, height: visible ? 12 : 5)
                    .opacity(visible ? 1 : 0.35)
                    .animation(
                        .easeInOut(duration: 0.45)
                            .repeatForever()
                            .delay(Double(index) * 0.14),
                        value: visible
                    )
            }
        }
        .frame(height: 12)
        .padding(.vertical, 2)
        .onAppear { visible = false }
    }
}

// MARK: - Shell result card (Auto Bash)

private struct ShellResultCard: View {
    let result: ShellRunResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.emerald)
                Text("BASH · \(result.target.label)")
                    .font(Theme.mono(9, .heavy))
                    .tracking(1)
                    .foregroundStyle(Theme.emerald)
                Spacer()
                Text("\(result.durationMs)MS")
                    .font(Theme.mono(9, .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("$")
                    .font(Theme.mono(12, .bold))
                    .foregroundStyle(Theme.emerald)
                Text(result.command)
                    .font(Theme.mono(12, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
            }

            if !result.output.isEmpty {
                Text(result.output)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(20)
                    .textSelection(.enabled)
            }

            Label(
                result.isOk ? "EXIT 0" : "EXIT \(result.exitCode)",
                systemImage: result.isOk ? "checkmark.circle.fill" : "xmark.circle.fill"
            )
            .font(Theme.mono(9, .heavy))
            .tracking(0.8)
            .foregroundStyle(result.isOk ? Theme.emerald : Theme.rose)
        }
        .padding(12)
        .background(Color(hex: 0x0C0C10), in: .rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(result.isOk ? Theme.emerald.opacity(0.25) : Theme.rose.opacity(0.35))
        )
    }
}

// MARK: - Agent tool card (Agent Mode live tools)

private struct AgentToolCard: View {
    let run: ToolRun

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.sky)
                Text("AGENT · \(run.name.uppercased())")
                    .font(Theme.mono(9, .heavy))
                    .tracking(1)
                    .foregroundStyle(Theme.sky)
                Spacer()
                Text("\(run.durationMs)MS")
                    .font(Theme.mono(9, .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }

            Text(run.argumentsPreview)
                .font(Theme.mono(11.5, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(4)
                .textSelection(.enabled)

            if !run.result.isEmpty {
                Text(run.result)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(16)
                    .textSelection(.enabled)
            }

            Label(run.isOK ? "OK" : "FAILED", systemImage: run.isOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(Theme.mono(9, .heavy))
                .tracking(0.8)
                .foregroundStyle(run.isOK ? Theme.emerald : Theme.rose)
        }
        .padding(12)
        .background(Color(hex: 0x0C0C10), in: .rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(run.isOK ? Theme.sky.opacity(0.28) : Theme.rose.opacity(0.35))
        )
    }
}

// MARK: - Segments

private struct Segment: Equatable {
    let text: String
    let isCode: Bool

    /// Splits streaming content into prose and fenced-code segments.
    static func parse(_ text: String) -> [Segment] {
        var result: [Segment] = []
        var current = ""
        var inCode = false

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    result.append(Segment(text: current, isCode: true))
                    current = ""
                } else if !current.isEmpty {
                    result.append(Segment(text: current, isCode: false))
                    current = ""
                }
                inCode.toggle()
            } else {
                current += (current.isEmpty ? "" : "\n") + line
            }
        }

        if !current.isEmpty {
            result.append(Segment(text: current, isCode: inCode))
        }
        return result
    }
}

#Preview("Assistant bubble") {
    ChatBubble(
        message: ChatMessage(
            role: .assistant,
            content: "Here's the module:\n\n```python\nprint(\"hello\")\n```",
            reasoning: "Simple code request.",
            timestamp: Date()
        )
    )
    .padding()
    .background(Theme.bgPrimary)
}
