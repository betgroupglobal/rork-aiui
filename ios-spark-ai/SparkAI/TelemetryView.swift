//
//  TelemetryView.swift
//  SparkAI
//

import SwiftUI

struct TelemetryView: View {
    @State private var viewModel = TelemetryViewModel.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    bannerCard
                    disclosureCard
                    gauges
                    meshSection
                    servicesSection
                }
                .padding(16)
                .padding(.bottom, 24)
            }
            .background(Theme.bgPrimary)
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("Spark Telemetry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bgPrimary, for: .navigationBar)
            .toolbarBackground(Theme.bgPrimary, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
            .refreshable { await viewModel.probeAll() }
            .overlay(alignment: .bottom) { probeStatus }
        }
    }

    // MARK: - Hardware banner

    private var bannerCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "cpu.fill")
                .font(.system(size: 20))
                .foregroundStyle(Theme.blue)
                .frame(width: 44, height: 44)
                .background(Theme.blueDim, in: .rect(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.telemetry.gpuModel)
                    .font(.system(size: 14.5, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Grace Blackwell · 128 GB coherent LPDDR5x · 273 GB/s · FP4 / NVFP4")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
            }

            Spacer()

            Button {
                Haptics.light()
                Task { await viewModel.probeAll() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .bold))
                        .rotationEffect(.degrees(viewModel.isProbing ? 360 : 0))
                        .animation(viewModel.isProbing ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: viewModel.isProbing)
                    Text(viewModel.isProbing ? "Probing" : "Probe")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.bgElevated, in: .rect(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
            }
            .disabled(viewModel.isProbing)
        }
        .padding(14)
        .background(Theme.bgSurface, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.border))
    }

    // MARK: - Simulated data disclosure

    private var disclosureCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Theme.amber)

            VStack(alignment: .leading, spacing: 3) {
                Text("SIMULATED TELEMETRY")
                    .font(Theme.mono(10.5, .heavy))
                    .tracking(1)
                    .foregroundStyle(Theme.amber)
                Text("GB10 gauges, mesh endpoints and microservices below are simulated demo data — no hardware is connected. Rows marked LIVE are updated by your real chat and page-scan requests.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Theme.amber.opacity(0.07), in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.amber.opacity(0.28)))
    }

    // MARK: - Gauges

    private var gauges: some View {
        VStack(spacing: 10) {
            sectionLabel("GB10 HARDWARE GAUGES · SIMULATED")

            let t = viewModel.telemetry
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    MetricGauge(
                        label: "GPU Temp",
                        value: String(format: "%.0f", t.gpuTemp),
                        unit: "°C",
                        sublabel: "Normal threshold (<\(Int(t.gpuTempMax))°C)",
                        progress: t.gpuTemp / t.gpuTempMax,
                        color: tempColor(t.gpuTemp),
                        icon: "flame.fill"
                    )
                    MetricGauge(
                        label: "Unified Memory",
                        value: String(format: "%.1f", t.vramUsedGb),
                        unit: "/ \(String(format: "%.0f", t.vramTotalGb)) GB",
                        sublabel: "\(Int(t.vramPercent * 100))% of \(Int(t.vramTotalGb)) GB CUDA-visible",
                        progress: t.vramPercent,
                        color: Theme.blue,
                        icon: "memorychip.fill"
                    )
                }
                HStack(spacing: 10) {
                    MetricGauge(
                        label: "Power Draw",
                        value: String(format: "%.0f", t.powerDrawWatts),
                        unit: "/ \(Int(t.powerLimitWatts)) W",
                        sublabel: "\(Int(t.powerPercent * 100))% of 140 W SOC TDP",
                        progress: t.powerPercent,
                        color: Theme.sky,
                        icon: "bolt.fill"
                    )
                    MetricGauge(
                        label: "Engine Clock",
                        value: String(format: "%.0f", t.gpuClockMhz),
                        unit: "MHz",
                        sublabel: "\(t.tensorCoresActive) SMs · mem \(Int(t.memoryClockMTs)) MT/s",
                        progress: t.gpuClockMhz / 2000,
                        color: Theme.amber,
                        icon: "waveform.path.ecg.rectangle"
                    )
                }
            }
        }
    }

    // MARK: - Mesh endpoints

    private var meshSection: some View {
        VStack(spacing: 10) {
            HStack {
                sectionLabel("MESH NETWORK ENDPOINTS · SEEDED")
                Spacer()
                if let event = viewModel.lastEvent {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(event.success ? Theme.blue : Theme.rose)
                            .frame(width: 5, height: 5)
                        Text("\(event.success ? "LIVE OK" : "LIVE FAIL") · \(String(format: "%.0f", event.latencyMs))MS")
                            .font(Theme.mono(9, .heavy))
                            .foregroundStyle(event.success ? Theme.blue : Theme.rose)
                            .tracking(0.6)
                            .lineLimit(1)
                    }
                } else {
                    Text("Zero-Config Failover")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.blue)
                }
            }

            VStack(spacing: 0) {
                ForEach(Array(viewModel.endpoints.enumerated()), id: \.element.id) { index, endpoint in
                    MeshEndpointRow(
                        endpoint: endpoint,
                        isActive: endpoint.id == viewModel.activeEndpointID
                    ) {
                        viewModel.setActiveEndpoint(endpoint)
                    }
                    if index < viewModel.endpoints.count - 1 {
                        Rectangle().fill(Theme.border).frame(height: 1)
                    }
                }
            }
            .background(Theme.bgSurface, in: .rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.border))
        }
    }

    // MARK: - Microservices

    private var servicesSection: some View {
        VStack(spacing: 10) {
            sectionLabel("MICROSERVICES · SIMULATED (\(viewModel.microservices.count))")

            ForEach(viewModel.microservices) { service in
                HStack(spacing: 12) {
                    Circle()
                        .fill(service.statusColor)
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(service.name)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(":\(service.port)")
                                .font(Theme.mono(11, .semibold))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Text("\(service.description) · \(service.model)")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Text(service.status.rawValue)
                        .font(Theme.mono(9, .heavy))
                        .tracking(0.8)
                        .foregroundStyle(service.statusColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(service.statusColor.opacity(0.12), in: .capsule)
                }
                .padding(14)
                .background(Theme.bgSurface, in: .rect(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
            }
        }
    }

    // MARK: - Helpers

    private var probeStatus: some View {
        Group {
            if viewModel.isProbing {
                Text("Probing all mesh endpoints…")
                    .font(Theme.mono(11, .semibold))
                    .foregroundStyle(Theme.blue)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.bgElevated.opacity(0.95), in: .capsule)
                    .overlay(Capsule().strokeBorder(Theme.border))
            }
        }
        .animation(.snappy, value: viewModel.isProbing)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(Theme.textTertiary)
    }

    private func tempColor(_ temp: Double) -> Color {
        if temp < 60 { return Theme.blue }
        if temp <= 75 { return Theme.amber }
        return Theme.rose
    }
}

// MARK: - Endpoint row

private struct MeshEndpointRow: View {
    let endpoint: MeshEndpoint
    let isActive: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(endpoint.name)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                        if isActive {
                            Text("ACTIVE ROUTE")
                                .font(Theme.mono(9, .heavy))
                                .tracking(0.5)
                                .foregroundStyle(Theme.blue)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.blueDim, in: .capsule)
                        }
                    }
                    Text("http://\(endpoint.host):\(endpoint.port)")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textTertiary)
                }

                Spacer()

                Text(endpoint.isOnline ? "\(String(format: "%.1f", endpoint.latencyMs)) ms" : "Offline")
                    .font(Theme.mono(13, .bold))
                    .foregroundStyle(endpoint.isOnline ? (endpoint.latencyMs <= 5 ? Theme.blue : Theme.amber) : Theme.rose)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(isActive ? Theme.bgElevated : .clear)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var dotColor: Color {
        if !endpoint.isOnline { return Theme.rose }
        return endpoint.isLan ? Theme.blue : Theme.amber
    }
}

#Preview {
    TelemetryView()
        .preferredColorScheme(.dark)
}
