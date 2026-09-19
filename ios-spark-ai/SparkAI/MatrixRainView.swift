//
//  MatrixRainView.swift
//  SparkAI
//
//  Ambient falling-glyph rain rendered on a TimelineView-driven Canvas —
//  the native translation of the source MatrixCanvasView.
//

import SwiftUI

struct MatrixRainView: View {
    var intensity: Double = 0.35

    @State private var columns: [RainColumn] = []

    private let glyphs = Array("アイウエオカキクケコサシスセソタチツテトナニヌネノ0123456789ABCDEF$#@%&")

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 16.0)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let glyphFont = Theme.mono(11, .semibold)

                for column in columns {
                    let trail: Int = 14
                    let cycle = size.height + CGFloat(trail) * 14
                    let head = (time * column.speed + column.offset).truncatingRemainder(dividingBy: cycle)

                    for step in 0..<trail {
                        let y = head - CGFloat(step) * 14
                        guard y > 0, y < size.height else { continue }

                        let glyph = glyphs[(column.seed + step * 7) % glyphs.count]
                        let fade = 1.0 - Double(step) / Double(trail)

                        let color: Color = step == 0
                            ? .white.opacity(0.85 * intensity / max(intensity, 0.001) * 0.6 + 0.15)
                            : Theme.sky.opacity(0.55 * fade * intensity)

                        context.draw(
                            Text(String(glyph)).font(glyphFont).foregroundColor(color),
                            at: CGPoint(x: column.x, y: y)
                        )
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear(perform: seedColumns)
        .onChange(of: intensity) { _, _ in seedColumns() }
    }

    private func seedColumns() {
        let count = max(10, Int(UIScreen.main.bounds.width / 16))
        var generator = SystemRandomNumberGenerator()
        columns = (0..<count).map { index in
            RainColumn(
                x: CGFloat(index) * 16 + 8,
                speed: Double.random(in: 40...110),
                offset: Double.random(in: 0...1200),
                seed: Int.random(in: 0..<4096, using: &generator)
            )
        }
    }
}

private struct RainColumn {
    let x: CGFloat
    let speed: Double
    let offset: Double
    let seed: Int
}

#Preview {
    MatrixRainView()
        .background(Theme.bgPrimary)
}
