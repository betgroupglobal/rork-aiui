//
//  Models.swift
//  SparkAI
//

import Foundation
import SwiftUI

enum MessageRole: Equatable, Codable {
    case user
    case assistant
}

/// Which inference route produced the latest reply.
enum InferenceRoute: Equatable {
    case edge0
    case spark
    case featherless
    case cloud
    case local
}

struct ChatMessage: Identifiable, Equatable, Codable {
    let id = UUID()
    let role: MessageRole
    var content: String
    var reasoning: String?
    let timestamp: Date
    var isStreaming = false
    /// Present when this message reports a sandbox shell execution.
    var shellResult: ShellRunResult?
    /// Present when this message reports an Agent Mode tool execution.
    var toolRun: ToolRun?

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id && lhs.content == rhs.content && lhs.isStreaming == rhs.isStreaming
            && lhs.shellResult == rhs.shellResult && lhs.toolRun == rhs.toolRun
    }
}

struct ChatSession: Identifiable, Equatable, Codable {
    let id = UUID()
    var title: String
    let createdAt: Date
    var messages: [ChatMessage]

    static func == (lhs: ChatSession, rhs: ChatSession) -> Bool {
        lhs.id == rhs.id && lhs.messages == rhs.messages
    }
}

struct HardwareTelemetry: Equatable {
    var gpuModel = "GB10 Grace Blackwell"
    var gpuTemp: Double = 46.5
    var gpuTempMax: Double = 85
    var vramUsedGb: Double = 38.4
    var vramTotalGb: Double = 120
    var unifiedSpecGb: Double = 128
    var powerDrawWatts: Double = 61
    var powerLimitWatts: Double = 140
    var gpuClockMhz: Double = 1447
    var memoryClockMTs: Double = 2730
    var tensorCoresActive = 96
    var isUnifiedMemory = true

    var vramPercent: Double { vramTotalGb > 0 ? vramUsedGb / vramTotalGb : 0 }
    var powerPercent: Double { powerLimitWatts > 0 ? powerDrawWatts / powerLimitWatts : 0 }
}

struct MeshEndpoint: Identifiable, Equatable {
    enum Kind: String {
        case directLan = "direct_lan"
        case secondaryLan = "secondary_lan"
        case tailscale
        case publicCloud = "public_cloud"
    }

    let id = UUID()
    let name: String
    let host: String
    let port: Int
    let kind: Kind
    var latencyMs: Double
    var isOnline: Bool

    var isLan: Bool { kind == .directLan || kind == .secondaryLan }
}

struct Microservice: Identifiable {
    enum Status: String {
        case online = "ONLINE"
        case ready = "READY"
        case standby = "STANDBY"
    }

    let id = UUID()
    let name: String
    let port: Int
    let model: String
    let description: String
    var status: Status

    var statusColor: Color {
        switch status {
        case .online: Theme.blue
        case .ready: Theme.sky
        case .standby: Theme.amber
        }
    }
}

