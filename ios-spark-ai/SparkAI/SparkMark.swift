//
//  SparkMark.swift
//  SparkAI
//
//  The in-app logo mark: a gradient bolt with a breathing halo and orbiting
//  circuit ring. Used in the header, empty state and launch intro.
//

import SwiftUI

struct SparkMark: View {
    var size: CGFloat = 84
    var isAnimated = true

    @State private var isBreathing = false
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Theme.sky.opacity(0.35), Theme.blue.opacity(0.08), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: size * 0.7
                    )
                )
                .frame(width: size * 1.4, height: size * 1.4)
                .scaleEffect(isBreathing ? 1.08 : 0.94)
                .opacity(isBreathing ? 1 : 0.7)

            Circle()
                .strokeBorder(
                    AngularGradient(
                        colors: [.clear, Theme.sky.opacity(0.9), .clear, Theme.blue.opacity(0.6), .clear],
                        center: .center
                    ),
                    lineWidth: max(1.2, size * 0.02)
                )
                .frame(width: size, height: size)
                .rotationEffect(.degrees(rotation))

            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .fill(Theme.sky)
                    .frame(width: size * 0.05, height: size * 0.05)
                    .offset(y: -size / 2)
                    .rotationEffect(.degrees(Double(index) * 90 + rotation * 0.6))
                    .opacity(0.8)
            }

            Circle()
                .fill(Theme.bgSurface)
                .frame(width: size * 0.78, height: size * 0.78)
                .overlay(Circle().strokeBorder(Theme.borderActive))

            Image(systemName: "bolt.fill")
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(Theme.spark)
                .shadow(color: Theme.sky.opacity(0.7), radius: size * 0.1)
                .scaleEffect(isBreathing ? 1.04 : 0.98)
        }
        .frame(width: size * 1.4, height: size * 1.4)
        .onAppear {
            guard isAnimated else { return }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                isBreathing = true
            }
            withAnimation(.linear(duration: 14).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
        .accessibilityHidden(true)
    }
}

/// Compact monogram for headers and tab labels — no halo, no motion.
struct SparkMonogram: View {
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: "bolt.fill")
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Theme.spark, in: .rect(cornerRadius: size * 0.32, style: .continuous))
            .shadow(color: Theme.blue.opacity(0.45), radius: 8, y: 3)
            .accessibilityHidden(true)
    }
}

#Preview {
    VStack(spacing: 30) {
        SparkMark()
        SparkMonogram()
    }
    .padding(40)
    .background(Theme.bgPrimary)
}
