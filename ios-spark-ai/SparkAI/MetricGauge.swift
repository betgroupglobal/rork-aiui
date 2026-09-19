//
//  MetricGauge.swift
//  SparkAI
//
//  Hardware metric card with animated progress bar — native translation of
//  the source MetricGauge component.
//

import SwiftUI

struct MetricGauge: View {
    let label: String
    let value: String
    let unit: String
    let sublabel: String
    let progress: Double // 0...1
    let color: Color
    let icon: String

    @State private var animatedProgress: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(Theme.display(22, .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())
                    .monospacedDigit()
                Text(unit)
                    .font(Theme.mono(10, .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.06))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.7), color],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: max(4, proxy.size.width * min(max(animatedProgress, 0), 1)))
                }
            }
            .frame(height: 5)

            Text(sublabel)
                .font(Theme.mono(9.5))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bgSurface, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.border))
        .onChange(of: progress) { _, newValue in
            withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) {
                animatedProgress = newValue
            }
        }
        .onAppear {
            animatedProgress = progress
        }
    }
}

#Preview {
    MetricGauge(
        label: "GPU Temperature",
        value: "47", unit: "°C",
        sublabel: "Normal threshold (<85°C)",
        progress: 0.55, color: Theme.blue, icon: "flame.fill"
    )
    .padding()
    .background(Theme.bgPrimary)
}
