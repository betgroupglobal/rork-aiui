//
//  TelemetryViewModel.swift
//  SparkAI
//
//  Simulated GB10 hardware telemetry with drifting values and mesh endpoint
//  probing. Structured so a real SSE telemetry bridge can replace the
//  drift loop later.
//

import Foundation

@Observable
@MainActor
final class TelemetryViewModel {
    static let shared = TelemetryViewModel()

    /// A real route event reported by chat traffic.
    struct MeshEvent: Equatable {
        let endpointName: String
        let success: Bool
        let latencyMs: Double
        let at: Date
    }

    private(set) var telemetry = HardwareTelemetry()
    private(set) var endpoints: [MeshEndpoint] = TelemetryViewModel.seedEndpoints
    private(set) var microservices: [Microservice] = TelemetryViewModel.seedServices
    private(set) var isProbing = false
    private(set) var activeEndpointID: UUID
    private(set) var lastEvent: MeshEvent?

    private var driftTask: Task<Void, Never>?

    init() {
        activeEndpointID = TelemetryViewModel.seedEndpoints[0].id
        driftTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.6))
                self.drift()
            }
        }
    }

    var activeEndpoint: MeshEndpoint? {
        endpoints.first { $0.id == activeEndpointID }
    }

    func probeAll() async {
        guard !isProbing else { return }
        isProbing = true
        try? await Task.sleep(for: .seconds(1.1))

        for index in endpoints.indices {
            guard endpoints[index].isOnline else { continue }
            let base: Double
            switch endpoints[index].kind {
            case .directLan, .secondaryLan: base = 0.4
            case .tailscale: base = 18
            case .publicCloud: base = 28
            }
            endpoints[index].latencyMs = Double.random(in: base...(base + 12)).rounded(toPlaces: 1)
        }
        telemetry.gpuTemp = Double.random(in: 42...58)
        isProbing = false
    }

    func setActiveEndpoint(_ endpoint: MeshEndpoint) {
        guard endpoint.isOnline, endpoint.id != activeEndpointID else { return }
        Haptics.medium()
        activeEndpointID = endpoint.id
        publishWidgetSnapshot()
    }

    /// Records real request activity from chat into the mesh view and
    /// republishes the Home Screen widget snapshot.
    func noteRouteActivity(endpointName: String, latencyMs: Double, success: Bool) {
        if let index = endpoints.firstIndex(where: { $0.name == endpointName }) {
            let observed = min(max(latencyMs, 1), 10_000)
            let smoothed = (endpoints[index].latencyMs * 0.6) + (observed * 0.4)
            endpoints[index].latencyMs = smoothed.rounded(toPlaces: 1)
            if success {
                endpoints[index].isOnline = true
            }
        }
        lastEvent = MeshEvent(endpointName: endpointName, success: success, latencyMs: latencyMs, at: Date())
        publishWidgetSnapshot()
    }

    private func publishWidgetSnapshot() {
        WidgetSnapshotStore.publish(
            TelemetrySnapshot(
                routeLabel: activeEndpoint?.name.uppercased() ?? "RORK AI CLOUD",
                gpuTemp: telemetry.gpuTemp,
                vramPercent: telemetry.vramPercent,
                powerPercent: telemetry.powerPercent,
                updatedAt: Date()
            )
        )
    }

    private func drift() {
        telemetry.gpuTemp = (telemetry.gpuTemp + Double.random(in: -1.2...1.4)).clamped(to: 39...72)
        telemetry.vramUsedGb = (telemetry.vramUsedGb + Double.random(in: -0.6...0.7)).clamped(to: 28...96)
        telemetry.powerDrawWatts = (telemetry.powerDrawWatts + Double.random(in: -3...3.4)).clamped(to: 38...118)
        telemetry.gpuClockMhz = (telemetry.gpuClockMhz + Double.random(in: -40...44)).clamped(to: 990...1750)
        telemetry.tensorCoresActive = Int.random(in: 72...128)
        publishWidgetSnapshot()
    }

    // MARK: - Seed data (mirrors the source mesh candidates)

    private static let seedEndpoints: [MeshEndpoint] = [
        MeshEndpoint(name: "Featherless Cloud", host: "api.featherless.ai", port: 443, kind: .publicCloud, latencyMs: 34.2, isOnline: true),
        MeshEndpoint(name: "Rork AI Cloud", host: "toolkit.rork.com", port: 443, kind: .publicCloud, latencyMs: 38.6, isOnline: true),
        MeshEndpoint(name: "Spark Direct LAN", host: "100.87.14.2", port: 8000, kind: .directLan, latencyMs: 0.4, isOnline: true),
        MeshEndpoint(name: "Edge0 Workstation", host: "192.168.1.44", port: 8085, kind: .secondaryLan, latencyMs: 2.4, isOnline: true),
        MeshEndpoint(name: "Sandbox Runner", host: "127.0.0.1", port: 17330, kind: .secondaryLan, latencyMs: 0.9, isOnline: true),
        MeshEndpoint(name: "Workstation LAN", host: "192.168.1.44", port: 8000, kind: .secondaryLan, latencyMs: 1.8, isOnline: true),
        MeshEndpoint(name: "Tailscale Relay", host: "100.64.0.7", port: 443, kind: .tailscale, latencyMs: 24.6, isOnline: true),
        MeshEndpoint(name: "Cloud Mirror", host: "spark-mirror.flak3dd.dev", port: 443, kind: .publicCloud, latencyMs: 0, isOnline: false),
    ]

    private static let seedServices: [Microservice] = [
        Microservice(name: "vLLM Inference", port: 8000, model: "abliterated-70b-fp4", description: "OpenAI-compatible streaming inference", status: .online),
        Microservice(name: "ComfyUI", port: 8188, model: "sd3.5-large", description: "Graph-based diffusion workflows", status: .ready),
        Microservice(name: "RAG Service", port: 17325, model: "nomic-embed", description: "Retrieval grounding + citations", status: .standby),
    ]
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }

    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
