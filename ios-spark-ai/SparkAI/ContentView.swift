//
//  ContentView.swift
//  SparkAI
//

import SwiftUI

struct ContentView: View {
    @State private var selection: Tab = .chat
    @State private var showIntro = true

    enum Tab: Hashable {
        case chat, monitor, telemetry
    }

    var body: some View {
        ZStack {
            TabView(selection: $selection) {
                ChatView()
                    .tabItem { Label("Chat", systemImage: "bolt.horizontal.fill") }
                    .tag(Tab.chat)

                PageMonitorView()
                    .tabItem { Label("Monitor", systemImage: "dot.radiowaves.left.and.right") }
                    .tag(Tab.monitor)

                TelemetryView()
                    .tabItem { Label("Telemetry", systemImage: "waveform.path.ecg.rectangle") }
                    .tag(Tab.telemetry)
            }
            .tint(Theme.sky)
            .onChange(of: selection) { _, _ in Haptics.selection() }

            if showIntro {
                LaunchIntroView {
                    withAnimation(.easeOut(duration: 0.45)) { showIntro = false }
                }
                .transition(.opacity)
                .zIndex(10)
            }
        }
    }
}

/// Two-second brand intro: the mark ignites, the wordmark types in, then
/// the whole layer dissolves into the chat.
private struct LaunchIntroView: View {
    let onFinish: () -> Void

    @State private var markScale: CGFloat = 0.6
    @State private var markOpacity: Double = 0
    @State private var revealedCharacters = 0
    @State private var tagline = false

    private let wordmark = Array("SPARK AI")

    var body: some View {
        ZStack {
            Theme.bgPrimary.ignoresSafeArea()
            MatrixRainView(intensity: 0.5)
                .opacity(0.35)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                SparkMark(size: 110)
                    .scaleEffect(markScale)
                    .opacity(markOpacity)

                HStack(spacing: 0) {
                    ForEach(Array(wordmark.enumerated()), id: \.offset) { index, character in
                        Text(String(character))
                            .font(Theme.display(30, .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .opacity(index < revealedCharacters ? 1 : 0)
                            .offset(y: index < revealedCharacters ? 0 : 8)
                    }
                }
                .tracking(6)

                Text("ABLITERATED · SELF-HOSTED · AGENTIC")
                    .font(Theme.mono(10, .semibold))
                    .tracking(2.4)
                    .foregroundStyle(Theme.sky)
                    .opacity(tagline ? 1 : 0)
            }
        }
        .task {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.65)) {
                markScale = 1
                markOpacity = 1
            }
            try? await Task.sleep(for: .milliseconds(350))
            for index in 1...wordmark.count {
                withAnimation(.snappy(duration: 0.18)) { revealedCharacters = index }
                Haptics.soft()
                try? await Task.sleep(for: .milliseconds(55))
            }
            withAnimation(Theme.reveal) { tagline = true }
            try? await Task.sleep(for: .milliseconds(900))
            onFinish()
        }
        .onTapGesture(perform: onFinish)
    }
}

#Preview {
    ContentView()
        .preferredColorScheme(.dark)
}
