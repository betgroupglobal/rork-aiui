//
//  CredentialVault.swift
//  SparkAI
//
//  Vault of site credentials imported from CSV (or produced by live runs).
//  Only metadata (domain, email, username) is stored on-device — the password
//  lives exclusively in the Keychain under "cred-<domain>". When a live run's
//  form domain matches a row here, the saved credential is reused instead of
//  minting a new alias/password.
//

import Foundation
import Observation

/// One saved site credential. The password never touches this struct or JSON —
/// it is read from the Keychain under "cred-<domain>".
nonisolated struct SiteCredential: Codable, Identifiable, Equatable {
    var id: UUID
    var domain: String
    var email: String
    var username: String
    var createdAt: Date

    init(id: UUID = UUID(), domain: String, email: String = "", username: String = "", createdAt: Date = Date()) {
        self.id = id
        self.domain = domain
        self.email = email
        self.username = username
        self.createdAt = createdAt
    }
}

@MainActor
@Observable
final class CredentialVault {
    static let shared = CredentialVault()

    static let templateCSV = """
    url,username,email,password
    https://example.com,ada,ada@example.com,S3cret!Pass1
    https://example.org,turing,alan@example.org,An0ther!Pass2
    """

    private(set) var credentials: [SiteCredential] = []
    private static let storeKey = "credential-vault"
    private static let cap = 80

    private init() {
        credentials = PersistenceStore.load([SiteCredential].self, forKey: Self.storeKey) ?? []
    }

    /// Finds the saved credential for a domain: exact match first, then
    /// subdomain match either way (mail.example.com ↔ example.com).
    func match(_ domain: String) -> SiteCredential? {
        let d = domain.lowercased()
        guard !d.isEmpty else { return nil }
        return credentials.first { $0.domain == d }
            ?? credentials.first { d.hasSuffix(".\($0.domain)") || $0.domain.hasSuffix(".\(d)") }
    }

    /// Reads the saved password for a credential from the Keychain.
    func password(for credential: SiteCredential) -> String? {
        KeychainService.password(account: "cred-\(credential.domain)")
    }

    /// Removes a credential and its Keychain password.
    func remove(_ id: UUID) {
        guard let credential = credentials.first(where: { $0.id == id }) else { return }
        KeychainService.deletePassword(account: "cred-\(credential.domain)")
        credentials.removeAll { $0.id == id }
        persist()
    }

    /// Wipes the vault including every Keychain password.
    func clear() {
        for credential in credentials {
            KeychainService.deletePassword(account: "cred-\(credential.domain)")
        }
        credentials = []
        persist()
    }

    /// Imports CSV text (header row required). Recognized columns: url/site/
    /// domain/host, email, username/user/login, password. Each row's password
    /// is moved straight into the Keychain; duplicates (same domain) replace
    /// the existing entry. Returns how many rows were imported.
    @discardableResult
    func importCSV(_ text: String) -> Int {
        let rows = CSVParser.parse(text)
        guard let header = rows.first else { return 0 }
        let columns = Self.columns(for: header)
        guard columns.contains(.domain) else { return 0 }

        var added = 0
        for row in rows.dropFirst() {
            var domain = ""
            var email = ""
            var username = ""
            var password = ""
            for (index, column) in columns.enumerated() where index < row.count {
                let value = row[index].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, let column else { continue }
                switch column {
                case .domain: domain = value
                case .email: email = value
                case .username: username = value
                case .password: password = value
                }
            }
            guard let normalized = Self.normalizeDomain(domain), !password.isEmpty else { continue }
            let credential = SiteCredential(domain: normalized, email: email, username: username)
            credentials.removeAll { $0.domain == normalized }
            credentials.append(credential)
            KeychainService.setPassword(password, account: "cred-\(normalized)")
            added += 1
        }
        credentials = Array(credentials.prefix(Self.cap))
        persist()
        return added
    }

    // MARK: - Normalization

    /// Reduces any URL-ish value to a bare host ("https://www.Example.com/x"
    /// → "example.com"). Returns nil when nothing usable remains.
    static func normalizeDomain(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !value.isEmpty else { return nil }
        if let url = URL(string: value), let host = url.host, !host.isEmpty {
            value = host
        } else {
            value = value.split(separator: "/").first.map(String.init) ?? value
        }
        if value.hasPrefix("www.") { value.removeFirst(4) }
        return value.contains(".") ? value : nil
    }

    // MARK: - Header mapping

    private enum CredentialColumn {
        case domain, email, username, password
    }

    /// Maps normalized header names to credential fields; unrecognized columns
    /// are kept as nil placeholders so row indices still line up.
    private static func columns(for header: [String]) -> [CredentialColumn?] {
        let map: [(CredentialColumn, Set<String>)] = [
            (.domain, ["url", "site", "website", "domain", "host", "server", "address", "loginurl", "loginuri"]),
            (.email, ["email", "emailaddress", "mail"]),
            (.username, ["username", "user", "login", "handle", "account", "name"]),
            (.password, ["password", "passwd", "pass", "pwd"])
        ]
        return header.map { raw in
            let normalized = raw.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            let key = String(String.UnicodeScalarView(normalized))
            return map.first { $0.1.contains(key) }?.0
        }
    }

    private func persist() {
        PersistenceStore.save(credentials, forKey: Self.storeKey)
    }
}
