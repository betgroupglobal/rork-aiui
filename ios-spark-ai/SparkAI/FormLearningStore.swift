//
//  FormLearningStore.swift
//  SparkAI
//
//  The automation ⇄ AI learning loop. Every sign-up run (manual sheet or
//  agent `signup_form`) appends a record; caller-key → field-identifier
//  mappings that worked are kept as per-domain aliases. Later runs consult
//  the aliases when a value doesn't match any identifier directly, and the
//  agent system prompt receives a compact per-domain digest so the model
//  reuses learned `fields` keys instead of guessing again.
//

import Foundation
import Observation

/// One completed automation run, kept for per-domain stats and prompt digest.
nonisolated struct FormLearningRecord: Codable {
    var domain: String
    var timestamp: Date
    /// "manual" (sheet), "agent" (signup_form tool), or "blind" (no parseable form).
    var mode: String
    var submitOK: Bool
    var httpStatus: Int
    var matchedKeys: [String]
    var aliasApplied: [String]
    var unmatched: [String]
    var missingRequired: [String]
    var got2FA: Bool?

    init(
        domain: String,
        timestamp: Date,
        mode: String,
        submitOK: Bool,
        httpStatus: Int,
        matchedKeys: [String],
        aliasApplied: [String],
        unmatched: [String],
        missingRequired: [String],
        got2FA: Bool? = nil
    ) {
        self.domain = domain
        self.timestamp = timestamp
        self.mode = mode
        self.submitOK = submitOK
        self.httpStatus = httpStatus
        self.matchedKeys = matchedKeys
        self.aliasApplied = aliasApplied
        self.unmatched = unmatched
        self.missingRequired = missingRequired
        self.got2FA = got2FA
    }

    /// Tolerates records saved before newer fields existed.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        domain = try container.decodeIfPresent(String.self, forKey: .domain) ?? ""
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? "manual"
        submitOK = try container.decodeIfPresent(Bool.self, forKey: .submitOK) ?? false
        httpStatus = try container.decodeIfPresent(Int.self, forKey: .httpStatus) ?? 0
        matchedKeys = try container.decodeIfPresent([String].self, forKey: .matchedKeys) ?? []
        aliasApplied = try container.decodeIfPresent([String].self, forKey: .aliasApplied) ?? []
        unmatched = try container.decodeIfPresent([String].self, forKey: .unmatched) ?? []
        missingRequired = try container.decodeIfPresent([String].self, forKey: .missingRequired) ?? []
        got2FA = try container.decodeIfPresent(Bool.self, forKey: .got2FA)
    }
}

/// A learned caller-key → field-identifier mapping with a hit counter.
nonisolated struct FieldAlias: Codable, Equatable {
    var identifier: String
    var hits: Int
}

@MainActor
@Observable
final class FormLearningStore {
    static let shared = FormLearningStore()

    private(set) var records: [FormLearningRecord] = []
    private(set) var aliases: [String: [String: FieldAlias]] = [:]

    private static let recordsKey = "form-learning-records"
    private static let aliasesKey = "form-learning-aliases"
    private static let recordsCap = 80
    private static let domainCap = 12
    private static let aliasesPerDomainCap = 20

    private init() {
        records = PersistenceStore.load([FormLearningRecord].self, forKey: Self.recordsKey) ?? []
        aliases = PersistenceStore.load([String: [String: FieldAlias]].self, forKey: Self.aliasesKey) ?? [:]
    }

    /// Registrable domain (host without www.) used as the learning key.
    func domain(for url: String) -> String {
        guard let host = URL(string: FormAutomationService.normalizedURL(url)?.absoluteString ?? url)?.host else {
            return url.lowercased()
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Appends a run outcome to the history.
    func record(_ record: FormLearningRecord) {
        records.insert(record, at: 0)
        if records.count > Self.recordsCap {
            records = Array(records.prefix(Self.recordsCap))
        }
        persist()
    }

    /// Stores (hit-incrementing) caller-key → identifier mappings that landed
    /// on a real form. Trivial identity mappings aren't knowledge and are skipped.
    func learnAliases(domain: String, mappings: [String: String]) {
        guard !mappings.isEmpty else { return }
        var domainAliases = aliases[domain] ?? [:]
        var changed = false
        for (callerKey, identifier) in mappings {
            let key = callerKey.lowercased()
            let id = identifier.lowercased()
            guard key != id, !key.isEmpty, !id.isEmpty else { continue }
            var alias = domainAliases[key] ?? FieldAlias(identifier: id, hits: 0)
            alias.identifier = id
            alias.hits += 1
            domainAliases[key] = alias
            changed = true
        }
        guard changed else { return }
        if domainAliases.count > Self.aliasesPerDomainCap {
            let keep = Set(domainAliases.sorted { $0.value.hits > $1.value.hits }.prefix(Self.aliasesPerDomainCap).map(\.key))
            domainAliases = domainAliases.filter { keep.contains($0.key) }
        }
        if aliases[domain] == nil, aliases.count >= Self.domainCap, let oldestDomain = records.last?.domain, let removed = aliases.removeValue(forKey: oldestDomain) {
            _ = removed
        }
        aliases[domain] = domainAliases
        persist()
    }

    /// Learned aliases for a domain — consulted by applyValues when direct
    /// identifier matching misses.
    func aliasMap(for domain: String) -> [String: String] {
        let map = aliases[domain] ?? [:]
        return map.mapValues(\.identifier)
    }

    /// One-line summary for the sheet's learning card.
    func summary(for domain: String) -> String? {
        let domainRecords = records.filter { $0.domain == domain }
        guard !domainRecords.isEmpty, let last = domainRecords.first else { return nil }
        let okCount = domainRecords.filter(\.submitOK).count
        let rate = Int((Double(okCount) / Double(domainRecords.count) * 100).rounded())
        var parts = ["\(domainRecords.count) run\(domainRecords.count == 1 ? "" : "s")", "\(rate)% OK"]
        let learned = aliases[domain]?.count ?? 0
        if learned > 0 { parts.append("\(learned) learned mapping\(learned == 1 ? "" : "s")") }
        parts.append(last.submitOK ? "last OK HTTP \(last.httpStatus)" : "last FAILED (HTTP \(last.httpStatus))")
        if last.got2FA == true { parts.append("2FA ✓") }
        return parts.joined(separator: " · ")
    }

    /// Digest injected into the agent system prompt — closes the loop so the
    /// model reuses keys that worked per site.
    func learningPrompt() -> String {
        guard !records.isEmpty else { return "" }
        var grouped: [String: [FormLearningRecord]] = [:]
        for record in records { grouped[record.domain, default: []].append(record) }
        var lines = ["FORM LEARNING — real automation history; reuse these `fields` keys per site:"]
        let recent = grouped.sorted { ($0.value.first?.timestamp ?? .distantPast) > ($1.value.first?.timestamp ?? .distantPast) }.prefix(3)
        for (domain, domainRecords) in recent {
            let okCount = domainRecords.filter(\.submitOK).count
            var line = "- \(domain): \(domainRecords.count) runs, \(okCount) ok"
            let learned = (aliases[domain] ?? [:])
                .sorted { $0.value.hits > $1.value.hits }
                .prefix(6)
                .map { "\($0.key)→\"\($0.value.identifier)\"" }
            if !learned.isEmpty { line += "; learned: \(learned.joined(separator: ", "))" }
            if let last = domainRecords.first {
                line += "; last: \(last.submitOK ? "OK HTTP \(last.httpStatus)" : "failed")"
            }
            lines.append(line)
        }
        lines.append("2FA email codes: \(EmailCodeService.shared.isConfigured ? "available — pass \"2fa\":true on signup_form" : "not configured")")
        return lines.joined(separator: "\n")
    }

    func clear() {
        records = []
        aliases = [:]
        persist()
    }

    private func persist() {
        PersistenceStore.save(records, forKey: Self.recordsKey)
        PersistenceStore.save(aliases, forKey: Self.aliasesKey)
    }
}
