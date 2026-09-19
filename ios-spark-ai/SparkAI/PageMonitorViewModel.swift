//
//  PageMonitorViewModel.swift
//  SparkAI
//
//  Owns the monitored-page list and the in-app monitoring loop. Pages are
//  re-checked on their interval: fetch → SHA-256 compare → AI scan (on
//  manual scans, first discovery or detected change), with AI calls gated
//  by the per-surface pageScan cloud consent.
//

import Foundation
import Observation

@MainActor
@Observable
final class PageMonitorViewModel {
    static let shared = PageMonitorViewModel()
    static let intervalChoices = [5, 15, 30, 60]

    private(set) var pages: [MonitoredPage] = []
    private(set) var scanningIDs: Set<UUID> = []
    private(set) var lastError: String?

    private let service = PageScanService()
    private var monitorTask: Task<Void, Never>?
    private static let storeKey = "page-monitor-pages"

    init() {
        pages = PersistenceStore.load([MonitoredPage].self, forKey: Self.storeKey) ?? []
        startMonitorLoop()
    }

    // MARK: - Mutations

    func addPage(urlString: String, intervalMinutes: Int) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !pages.contains(where: { $0.url.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            lastError = "That page is already being monitored"
            return
        }
        let host = URL(string: FormAutomationService.normalizedURL(trimmed)?.absoluteString ?? trimmed)?.host ?? trimmed
        let page = MonitoredPage(url: trimmed, label: host, intervalMinutes: intervalMinutes)
        pages.insert(page, at: 0)
        lastError = nil
        persist()
        Task { await scan(page.id, runAI: true) }
    }

    func remove(_ id: UUID) {
        pages.removeAll { $0.id == id }
        persist()
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[index].isEnabled = enabled
        persist()
    }

    func setInterval(_ id: UUID, _ minutes: Int) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[index].intervalMinutes = minutes
        persist()
    }

    func scanNow(_ id: UUID) {
        Task { await scan(id, runAI: true) }
    }

    // MARK: - Scanning

    /// Fetches, hashes and (when warranted) AI-scans one page. Hash checks
    /// always run; AI analysis needs consent and a trigger — manual scan,
    /// first discovery, or a detected content change.
    private func scan(_ id: UUID, runAI: Bool) async {
        guard let index = pages.firstIndex(where: { $0.id == id }),
              !scanningIDs.contains(id) else { return }
        let page = pages[index]
        scanningIDs.insert(id)
        defer { scanningIDs.remove(id) }

        let fetch = await service.fetch(page.url)
        var updated = page
        updated.lastCheckedAt = Date()
        updated.lastHTTPStatus = fetch.statusCode

        // Network failure or non-2xx/3xx: keep the old hash and summary.
        let networkError = fetch.error ?? ((200..<400).contains(fetch.statusCode) ? nil : "HTTP \(fetch.statusCode)")
        if let error = networkError {
            updated.lastOutcome = "error"
            updated.lastErrorMessage = error
            pages[index] = updated
            persist()
            return
        }

        let changed = !page.lastHash.isEmpty && page.lastHash != fetch.hash
        updated.lastHash = fetch.hash
        updated.lastOutcome = changed ? "changed" : "ok"
        updated.lastErrorMessage = nil
        if changed {
            updated.lastChangedAt = Date()
            updated.changeCount += 1
        }
        pages[index] = updated
        if changed { Haptics.medium() }

        guard runAI || changed || page.aiSummary.isEmpty,
              CloudConsent.isAccepted(.pageScan) else {
            persist()
            return
        }

        do {
            let startedAt = Date()
            let summary = try await service.aiScan(
                pageURL: page.url,
                pageText: fetch.text,
                previousSummary: page.aiSummary,
                changed: changed
            )
            TelemetryViewModel.shared.noteRouteActivity(
                endpointName: "Rork AI Cloud",
                latencyMs: Double(Int(Date().timeIntervalSince(startedAt) * 1000)),
                success: true
            )
            if let i = pages.firstIndex(where: { $0.id == id }) {
                pages[i].aiSummary = summary.isEmpty ? "(the model returned an empty report)" : summary
            }
            persist()
        } catch {
            TelemetryViewModel.shared.noteRouteActivity(
                endpointName: "Rork AI Cloud",
                latencyMs: 0,
                success: false
            )
            lastError = "AI scan failed: \(error.localizedDescription)"
            persist()
        }
    }

    // MARK: - Monitor loop

    /// Re-checks due pages while the app is open (iOS suspends background
    /// work, so monitoring is a foreground promise).
    private func startMonitorLoop() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self?.checkDuePages()
            }
        }
    }

    private func checkDuePages() async {
        let now = Date()
        for page in pages where page.isEnabled {
            let interval = TimeInterval(page.intervalMinutes * 60)
            let last = page.lastCheckedAt ?? .distantPast
            guard now.timeIntervalSince(last) >= interval else { continue }
            await scan(page.id, runAI: false)
        }
    }

    private func persist() {
        PersistenceStore.save(pages, forKey: Self.storeKey)
    }
}
