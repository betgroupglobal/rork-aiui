//
//  SparkAIWidget.swift
//  SparkAIWidget
//
//  Home Screen / Lock Screen widget showing the active inference route and a
//  simulated GB10 telemetry snapshot published by the app through an App Group.
//

import SwiftUI
import WidgetKit

nonisolated struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: TelemetrySnapshot.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: .now, snapshot: WidgetSnapshotStore.load() ?? .sample))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: .now, snapshot: WidgetSnapshotStore.load() ?? .sample)
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

nonisolated struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: TelemetrySnapshot?
}

struct SparkAIWidget: Widget {
    let kind: String = "SparkAIWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            SparkTelemetryView(entry: entry)
        }
        .configurationDisplayName("Spark Telemetry")
        .description("Active inference route and simulated GB10 stats.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

// MARK: - Widget views

private struct SparkTelemetryView: View {
    var entry: Provider.Entry

    private let bg = Color(widgetHex: 0x09090B)
    private let blue = Color(widgetHex: 0x3B82F6)
    private let sky = Color(widgetHex: 0x38BDF8)
    private let amber = Color(widgetHex: 0xF59E0B)

    var body: some View {
        switch entry.snapshot {
        case .some(let snapshot):
            content(snapshot)
                .containerBackground(for: .widget) { bg }
        case nil:
            noData()
                .containerBackground(for: .widget) { bg }
        }
    }

    private func content(_ snapshot: TelemetrySnapshot) -> some View {
        Group {
            if #available(iOS 18.0, *) {
                switch family {
                case .systemSmall: small(snapshot)
                case .systemMedium: medium(snapshot)
                case .accessoryCircular: circular(snapshot)
                default: rectangular(snapshot)
                }
            } else {
                small(snapshot)
            }
        }
    }

    @Environment(\.widgetFamily) private var family

    // MARK: Home Screen small

    private func small(_ snapshot: TelemetrySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Circle()
                    .fill(blue)
                    .frame(width: 6, height: 6)
                Text("SPARK AI · SIM")
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .tracking(1)
                Spacer()
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(blue)
            }

            Text(snapshot.routeLabel)
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(sky)
                .lineLimit(2)
                .minimumScaleFactor(0.7)

            Spacer()

            HStack {
                stat("TEMP", value: String(format: "%.0f°C", snapshot.gpuTemp), color: tempColor(snapshot.gpuTemp))
                Spacer()
                ring(progress: snapshot.vramPercent, label: "VRAM")
            }
        }
    }

    // MARK: Home Screen medium

    private func medium(_ snapshot: TelemetrySnapshot) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(blue)
                        .frame(width: 6, height: 6)
                    Text("SPARK AI · GB10 SIM")
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .tracking(1)
                }
                Text(snapshot.routeLabel)
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(sky)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Text(snapshot.updatedAt, style: .relative)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
            }

            Spacer()

            VStack(spacing: 10) {
                ring(progress: snapshot.vramPercent, label: "VRAM")
                ring(progress: snapshot.powerPercent, label: "PWR")
                stat("TEMP", value: String(format: "%.0f°C", snapshot.gpuTemp), color: tempColor(snapshot.gpuTemp))
            }
        }
    }

    // MARK: Lock Screen

    private func circular(_ snapshot: TelemetrySnapshot) -> some View {
        Gauge(value: snapshot.gpuTemp, in: 30...85) {
            Image(systemName: "bolt.fill")
        } currentValueLabel: {
            Text("\(Int(snapshot.gpuTemp))°")
                .font(.system(size: 12, weight: .heavy, design: .monospaced))
        }
        .gaugeStyle(.accessoryCircular)
        .tint(tempColor(snapshot.gpuTemp))
    }

    private func rectangular(_ snapshot: TelemetrySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(blue)
                Text("SPARK AI · SIM")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                Spacer()
                Text("\(Int(snapshot.gpuTemp))°C")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(tempColor(snapshot.gpuTemp))
            }
            Text(snapshot.routeLabel)
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(sky)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("VRAM \(Int(snapshot.vramPercent * 100))% · PWR \(Int(snapshot.powerPercent * 100))%")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    // MARK: Pieces

    private func noData() -> some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
            Text("Simulated telemetry · open Spark AI")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
        }
        .padding(12)
    }

    private func stat(_ label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
                .tracking(0.8)
            Text(value)
                .font(.system(size: 15, weight: .heavy, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    private func ring(progress: Double, label: String) -> some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.12), lineWidth: 4)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, progress)))
                .stroke(blue, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(progress * 100))")
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
        }
        .frame(width: 34, height: 34)
        .overlay(alignment: .bottom) {
            Text(label)
                .font(.system(size: 7, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
                .tracking(0.6)
                .offset(y: 9)
        }
        .padding(.bottom, 9)
    }

    private func tempColor(_ temp: Double) -> Color {
        if temp < 60 { return blue }
        if temp <= 75 { return amber }
        return Color(widgetHex: 0xF43F5E)
    }
}

#if DEBUG
#Preview("Small", as: .systemSmall) {
    SparkAIWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: TelemetrySnapshot.sample)
}
#endif
