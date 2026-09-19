//
//  TelemetrySnapshot.swift
//  SparkAIWidget
//
//  Widget-target copy of the app-side snapshot model. Both targets must
//  decode the same App Group payload shape.
//

import Foundation
import SwiftUI

nonisolated struct TelemetrySnapshot: Codable {
    var routeLabel: String
    var gpuTemp: Double
    var vramPercent: Double
    var powerPercent: Double
    var updatedAt: Date

    static let sample = TelemetrySnapshot(
        routeLabel: "RORK AI CLOUD",
        gpuTemp: 46.5,
        vramPercent: 0.32,
        powerPercent: 0.44,
        updatedAt: Date()
    )
}

nonisolated enum WidgetSnapshotStore {
    static let appGroupID = "group.app.rork.9hqiqxlq2o87zwgskq5tw.spark"
    private static let key = "telemetry-snapshot"

    static func load() -> TelemetrySnapshot? {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(TelemetrySnapshot.self, from: data)
    }
}

extension Color {
    init(widgetHex hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
