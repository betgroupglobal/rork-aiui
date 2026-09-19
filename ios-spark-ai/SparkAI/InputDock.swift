//
//  InputDock.swift
//  SparkAI
//

import SwiftUI

struct InputDock: View {
    @Binding var text: String
    let isStreaming: Bool
    let onSend: (String) -> Void
    let onStop: () -> Void
    let isAgentMode: Bool
    let onToggleAgent: () -> Void

    @State private var dictation = DictationService()
    @State private var sendPulse = false
    @FocusState private var isFocused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool { !trimmed.isEmpty }

    var body: some View {
        VStack(spacing: 8) {
            if let status = dictation.statusMessage {
                Text(status)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.amber)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if isAgentMode {
                HStack(spacing: 6) {
                    Image(systemName: "cpu")
                        .font(.system(size: 9, weight: .bold))
                    Text("AGENT MODE · NATIVE TOOLS · MULTI-HOP")
                        .font(Theme.mono(9, .bold))
                        .tracking(1.2)
                    Spacer()
                }
                .foregroundStyle(Theme.sky)
                .padding(.horizontal, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button(action: onToggleAgent) {
                    IconChip(systemName: isAgentMode ? "wand.and.stars" : "wand.and.rays", tint: Theme.sky, isActive: isAgentMode, size: 42, cornerRadius: 21)
                        .symbolEffect(.bounce, value: isAgentMode)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(isAgentMode ? "Disable agent mode" : "Enable agent mode")

                HStack(alignment: .bottom, spacing: 6) {
                    TextField("Message Spark…", text: $text, axis: .vertical)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textPrimary)
                        .tint(Theme.sky)
                        .lineLimit(1...5)
                        .focused($isFocused)
                        .padding(.leading, 14)
                        .padding(.vertical, 11)
                        .onSubmit { submit() }

                    Button {
                        dictation.toggleDictation { transcript in
                            text = transcript
                        }
                    } label: {
                        Image(systemName: dictation.isRecording ? "waveform" : "mic.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(dictation.isRecording ? Theme.rose : Theme.textTertiary)
                            .frame(width: 36, height: 42)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.pressable)
                    .symbolEffect(.variableColor.iterative, isActive: dictation.isRecording)
                    .accessibilityLabel(dictation.isRecording ? "Stop dictation" : "Dictate")
                }
                .background(Theme.bgSurface, in: .rect(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(
                            isFocused
                                ? AnyShapeStyle(Theme.spark.opacity(0.7))
                                : AnyShapeStyle(dictation.isRecording ? Theme.rose.opacity(0.5) : Theme.border),
                            lineWidth: isFocused ? 1.2 : 1
                        )
                )
                .shadow(color: isFocused ? Theme.blue.opacity(0.22) : .clear, radius: 14, y: 4)
                .animation(Theme.snap, value: isFocused)

                Button {
                    if isStreaming {
                        Haptics.medium()
                        onStop()
                    } else {
                        submit()
                    }
                } label: {
                    ZStack {
                        if isStreaming {
                            Circle()
                                .strokeBorder(Theme.rose.opacity(0.5), lineWidth: 1.5)
                                .scaleEffect(sendPulse ? 1.35 : 1)
                                .opacity(sendPulse ? 0 : 0.8)
                        }
                        Group {
                            if isStreaming {
                                Image(systemName: "stop.fill")
                                    .foregroundStyle(Theme.rose)
                            } else {
                                Image(systemName: "arrow.up")
                                    .foregroundStyle(.white)
                            }
                        }
                        .font(.system(size: 16, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                    }
                    .frame(width: 42, height: 42)
                    .background {
                        if isStreaming {
                            Circle().fill(Theme.bgElevated)
                        } else {
                            Circle().fill(Theme.spark)
                        }
                    }
                    .overlay(Circle().strokeBorder(isStreaming ? Theme.rose.opacity(0.4) : Theme.border))
                    .shadow(color: canSend && !isStreaming ? Theme.blue.opacity(0.45) : .clear, radius: 12, y: 4)
                }
                .buttonStyle(.pressable(scale: 0.88, haptic: false))
                .disabled(!isStreaming && !canSend)
                .opacity(!isStreaming && !canSend ? 0.45 : 1)
                .scaleEffect(canSend || isStreaming ? 1 : 0.94)
                .animation(Theme.snap, value: canSend)
                .accessibilityLabel(isStreaming ? "Stop generating" : "Send")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial.opacity(0.5))
        .animation(Theme.snap, value: isAgentMode)
        .animation(Theme.snap, value: dictation.statusMessage != nil)
        .onChange(of: isStreaming) { _, streaming in
            if streaming {
                withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { sendPulse = true }
            } else {
                sendPulse = false
            }
        }
    }

    private func submit() {
        let payload = text
        guard canSend else { return }
        Haptics.medium()
        dictation.stop()
        isFocused = false
        onSend(payload)
    }
}

#Preview {
    InputDock(
        text: .constant(""),
        isStreaming: false,
        onSend: { _ in },
        onStop: {},
        isAgentMode: true,
        onToggleAgent: {}
    )
    .background(Theme.bgPrimary)
}
