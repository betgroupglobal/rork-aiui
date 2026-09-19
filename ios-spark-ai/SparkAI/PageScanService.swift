//
//  PageScanService.swift
//  SparkAI
//
//  AI-powered page scanning and monitoring. Fetches a page, hashes its
//  visible text (SHA-256) to detect changes, and sends the content through
//  the Rork AI cloud route for a structured scan report. Fetch + hashing
//  stay fully on-device; only the AI analysis leaves, gated by consent.
//

import Foundation
import CryptoKit

/// A webpage registered for AI scanning and change monitoring.
nonisolated struct MonitoredPage: Codable, Identifiable, Equatable {
    let id: UUID
    var url: String
    var label: String
    /// Re-check cadence in minutes.
    var intervalMinutes: Int
    var isEnabled: Bool
    var lastCheckedAt: Date?
    /// Hash of the page's visible text at the last successful check.
    var lastHash: String
    var lastHTTPStatus: Int
    /// "ok", "changed" or "error".
    var lastOutcome: String
    var lastErrorMessage: String?
    var lastChangedAt: Date?
    var changeCount: Int
    /// Latest AI scan report (markdown).
    var aiSummary: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        url: String,
        label: String,
        intervalMinutes: Int = 15,
        isEnabled: Bool = true,
        lastCheckedAt: Date? = nil,
        lastHash: String = "",
        lastHTTPStatus: Int = -1,
        lastOutcome: String = "",
        lastErrorMessage: String? = nil,
        lastChangedAt: Date? = nil,
        changeCount: Int = 0,
        aiSummary: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.url = url
        self.label = label
        self.intervalMinutes = intervalMinutes
        self.isEnabled = isEnabled
        self.lastCheckedAt = lastCheckedAt
        self.lastHash = lastHash
        self.lastHTTPStatus = lastHTTPStatus
        self.lastOutcome = lastOutcome
        self.lastErrorMessage = lastErrorMessage
        self.lastChangedAt = lastChangedAt
        self.changeCount = changeCount
        self.aiSummary = aiSummary
        self.createdAt = createdAt
    }

    /// Tolerates snapshots saved before newer fields existed.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        intervalMinutes = try container.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 15
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        lastCheckedAt = try container.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
        lastHash = try container.decodeIfPresent(String.self, forKey: .lastHash) ?? ""
        lastHTTPStatus = try container.decodeIfPresent(Int.self, forKey: .lastHTTPStatus) ?? -1
        lastOutcome = try container.decodeIfPresent(String.self, forKey: .lastOutcome) ?? ""
        lastErrorMessage = try container.decodeIfPresent(String.self, forKey: .lastErrorMessage)
        lastChangedAt = try container.decodeIfPresent(Date.self, forKey: .lastChangedAt)
        changeCount = try container.decodeIfPresent(Int.self, forKey: .changeCount) ?? 0
        aiSummary = try container.decodeIfPresent(String.self, forKey: .aiSummary) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

/// Fetches pages, hashes their visible text and runs AI scan reports
/// through the cloud inference route.
nonisolated final class PageScanService {
    private let cloud = CloudInferenceService()

    struct PageFetch: Equatable {
        let text: String
        let hash: String
        let statusCode: Int
        let durationMs: Int
        /// Network-level failure message; `nil` when the fetch completed.
        let error: String?
    }

    /// Fetches the page and returns its visible text with a content hash.
    func fetch(_ urlString: String) async -> PageFetch {
        let startedAt = Date()
        let duration: () -> Int = { Int(Date().timeIntervalSince(startedAt) * 1000) }
        guard let url = FormAutomationService.normalizedURL(urlString) else {
            return PageFetch(text: "", hash: "", statusCode: -1, durationMs: 0, error: "Invalid URL")
        }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
                forHTTPHeaderField: "User-Agent"
            )
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let html = String(data: data, encoding: .utf8) ?? ""
            let text = FormAutomationService.stripTags(html)
            let digest = SHA256.hash(data: Data(text.utf8))
            let hash = digest.map { String(format: "%02x", $0) }.joined()
            return PageFetch(
                text: text,
                hash: String(hash.prefix(32)),
                statusCode: status,
                durationMs: duration(),
                error: nil
            )
        } catch {
            return PageFetch(text: "", hash: "", statusCode: -1, durationMs: duration(), error: error.localizedDescription)
        }
    }

    /// Sends the page's visible text through the cloud AI route for a
    /// structured scan report. Only stripped page text is transmitted —
    /// never headers, cookies or device data.
    func aiScan(pageURL: String, pageText: String, previousSummary: String, changed: Bool) async throws -> String {
        let trimmed: String
        if pageText.count > 6000 {
            trimmed = String(pageText.prefix(4500)) + "\n…[middle trimmed]…\n" + String(pageText.suffix(1200))
        } else {
            trimmed = pageText
        }

        var user = "URL: \(pageURL)\n\nPAGE TEXT:\n\(trimmed)"
        if changed, !previousSummary.isEmpty {
            user += "\n\nPRIOR SUMMARY (the content hash changed since then — lead with what most likely changed):\n\(previousSummary)"
        }

        var output = ""
        for try await event in cloud.stream(history: [ChatTurn(role: "user", content: user)], systemPrompt: Self.scanPrompt) {
            if case .content(let delta) = event { output += delta }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let scanPrompt = """
    You are Spark AI's page scanner in a DGX Spark mesh console. You receive the \
    visible text of a webpage and produce a tight technical scan report:
    1. First line: "PAGE:" plus what this page is in under 12 words.
    2. Then 2-4 markdown bullets with the most notable concrete facts (titles, \
    prices, versions, statuses, dates, forms, counts).
    3. If the page requests credentials, payment or personal data, add a "RISK:" bullet.
    4. If told the page changed since a prior scan, start with what most likely changed.
    Only use facts present in the text — never invent details. Maximum 120 words.
    """
}
