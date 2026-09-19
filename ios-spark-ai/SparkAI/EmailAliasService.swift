//
//  EmailAliasService.swift
//  SparkAI
//
//  emailalias.io REST client: mints random forwarding aliases used as the
//  email address during live credentials runs. Mail sent to an alias lands
//  in the account's verified primary inbox — which Spark reads over IMAP
//  (EmailCodeService) — so the target site never sees the real address.
//  The API key (ea_live_…) is stored only in the device Keychain.
//

import Foundation
import Observation

/// User-editable alias behavior (persisted JSON; the API key lives in the
/// Keychain).
nonisolated struct EmailAliasSettings: Codable, Equatable {
    /// When true, live runs mint a fresh alias for every email field.
    var isEnabled: Bool
    /// Optional prefix prepended to auto labels (e.g. "spark" → "spark-site-com").
    var labelPrefix: String

    init(isEnabled: Bool = true, labelPrefix: String = "") {
        self.isEnabled = isEnabled
        self.labelPrefix = labelPrefix
    }

    /// Tolerates settings saved before newer fields existed.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        labelPrefix = try container.decodeIfPresent(String.self, forKey: .labelPrefix) ?? ""
    }
}

/// One forwarding alias as returned by the emailalias.io API.
nonisolated struct EmailAlias: Codable, Equatable, Sendable {
    let id: String
    let aliasEmail: String
    let destinationEmail: String
    let label: String
    let active: Bool

    init(id: String = "", aliasEmail: String, destinationEmail: String, label: String, active: Bool = true) {
        self.id = id
        self.aliasEmail = aliasEmail
        self.destinationEmail = destinationEmail
        self.label = label
        self.active = active
    }

    /// Maps the API's snake_case fields; tolerates missing optionals.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        aliasEmail = try container.decodeIfPresent(String.self, forKey: .aliasEmail) ?? ""
        destinationEmail = try container.decodeIfPresent(String.self, forKey: .destinationEmail) ?? ""
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case aliasEmail = "alias_email"
        case destinationEmail = "destination_email"
        case label
        case active
    }
}

nonisolated enum EmailAliasError: Error, Equatable {
    case notConfigured
    case invalidKey
    case rateLimited
    case requestFailed(String)

    var message: String {
        switch self {
        case .notConfigured: return "emailalias.io API key not set"
        case .invalidKey: return "API key rejected — check the ea_live_ key"
        case .rateLimited: return "emailalias.io rate limit hit (20 aliases/day on Premium)"
        case .requestFailed(let detail): return "Alias request failed: \(detail)"
        }
    }
}

/// Talks to https://emailalias.io/api with Bearer-token auth.
@MainActor
@Observable
final class EmailAliasService {
    static let shared = EmailAliasService()

    private(set) var settings: EmailAliasSettings
    private(set) var hasAPIKey: Bool

    private static let settingsKey = "email-alias-settings"
    private static let apiKeyAccount = "emailalias-api-key"
    private static let apiBase = "https://emailalias.io/api"

    private init() {
        settings = PersistenceStore.load(EmailAliasSettings.self, forKey: Self.settingsKey) ?? EmailAliasSettings()
        hasAPIKey = KeychainService.password(account: Self.apiKeyAccount) != nil
    }

    var isConfigured: Bool { hasAPIKey }

    func update(_ newSettings: EmailAliasSettings) {
        settings = newSettings
        PersistenceStore.save(settings, forKey: Self.settingsKey)
    }

    func saveAPIKey(_ key: String) {
        KeychainService.setPassword(key, account: Self.apiKeyAccount)
        hasAPIKey = !key.isEmpty
    }

    func deleteAPIKey() {
        KeychainService.deletePassword(account: Self.apiKeyAccount)
        hasAPIKey = false
    }

    /// Mints a random forwarding alias. `label` is free-form — live runs pass
    /// the target site's domain so the alias is identifiable in the dashboard.
    func createAlias(label: String) async throws -> EmailAlias {
        guard let key = KeychainService.password(account: Self.apiKeyAccount), !key.isEmpty else {
            throw EmailAliasError.notConfigured
        }
        guard let url = URL(string: "\(Self.apiBase)/aliases") else {
            throw EmailAliasError.requestFailed("bad endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let prefix = settings.labelPrefix.isEmpty ? "" : "\(settings.labelPrefix)-"
        let body: [String: String] = ["alias_type": "random", "label": prefix + label]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let startedAt = Date()
        func note(_ success: Bool) {
            TelemetryViewModel.shared.noteRouteActivity(
                endpointName: "Email alias (emailalias.io)",
                latencyMs: Date().timeIntervalSince(startedAt) * 1000,
                success: success
            )
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            switch status {
            case 200..<300:
                guard let alias = try? JSONDecoder().decode(EmailAlias.self, from: data),
                      !alias.aliasEmail.isEmpty else {
                    note(false)
                    throw EmailAliasError.requestFailed("unexpected response shape")
                }
                note(true)
                return alias
            case 401, 403:
                note(false)
                throw EmailAliasError.invalidKey
            case 429:
                note(false)
                throw EmailAliasError.rateLimited
            default:
                note(false)
                throw EmailAliasError.requestFailed("HTTP \(status)")
            }
        } catch let error as EmailAliasError {
            throw error
        } catch {
            note(false)
            throw EmailAliasError.requestFailed(error.localizedDescription)
        }
    }

    /// Lists existing aliases — proves the key works, for the settings sheet.
    func testConnection() async throws -> String {
        guard let key = KeychainService.password(account: Self.apiKeyAccount), !key.isEmpty else {
            throw EmailAliasError.notConfigured
        }
        guard let url = URL(string: "\(Self.apiBase)/aliases") else {
            throw EmailAliasError.requestFailed("bad endpoint")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        switch status {
        case 200..<300:
            guard let aliases = try? JSONDecoder().decode([EmailAlias].self, from: data) else {
                throw EmailAliasError.requestFailed("unexpected response shape")
            }
            let active = aliases.filter(\.active).count
            return "KEY OK · \(aliases.count) alias\(aliases.count == 1 ? "" : "es") (\(active) active)"
        case 401, 403:
            throw EmailAliasError.invalidKey
        case 429:
            throw EmailAliasError.rateLimited
        default:
            throw EmailAliasError.requestFailed("HTTP \(status)")
        }
    }
}
