//
//  WidgetSnapshot.swift
//  SparkAI
//
//  Telemetry snapshot shared with the Home Screen widget through an
//  App Group. Both the app and the widget target carry a copy of this file.
//

import Foundation

nonisolated struct TelemetrySnapshot: Codable {
    var routeLabel: String
    var gpuTemp: Double
    var vramPercent: Double
    var powerPercent: Double
    var updatedAt: Date

    nonisolated static let sample = TelemetrySnapshot(
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

    static func publish(_ snapshot: TelemetrySnapshot) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: key)
        }
    }

    static func load() -> TelemetrySnapshot? {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(TelemetrySnapshot.self, from: data)
    }
}
