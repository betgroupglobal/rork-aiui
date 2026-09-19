//
//  LiveRunService.swift
//  SparkAI
//
//  The live credentials run: the form automator kicks off first, and every
//  action the discovered fields demand fires as they are found — an email
//  field mints a fresh emailalias.io alias (forwards to the user's real
//  inbox), password fields get a generated strong password, identity fields
//  pull from the people roster. After a successful submit the real inbox is
//  polled over IMAP for the verification code. Credentials (alias + username
//  + password) are stored with the password in the Keychain only.
//

import Foundation
import Observation

/// One streamed step of a live run, for the report card and agent output.
nonisolated struct LiveRunStep: Identifiable, Equatable {
    let id: UUID
    var title: String
    var detail: String
    var isOK: Bool

    init(title: String, detail: String = "", isOK: Bool = true) {
        self.id = UUID()
        self.title = title
        self.detail = detail
        self.isOK = isOK
    }
}

/// A credential produced by a live run. The password never touches JSON —
/// it is read from the Keychain under "cred-<domain>".
nonisolated struct GeneratedCredential: Codable, Identifiable, Equatable {
    var id: UUID
    var domain: String
    var email: String
    var username: String
    var createdAt: Date

    init(id: UUID = UUID(), domain: String, email: String, username: String, createdAt: Date = Date()) {
        self.id = id
        self.domain = domain
        self.email = email
        self.username = username
        self.createdAt = createdAt
    }
}

@MainActor
final class LiveRunService {
    static let shared = LiveRunService()

    private let automation = FormAutomationService()
    private static let credentialKey = "generated-credentials"

    struct Outcome {
        var steps: [LiveRunStep] = []
        var fields: [FormField] = []
        var result: FormSubmitResult?
        var code: VerificationCode?
        var credential: GeneratedCredential?

        var isOK: Bool { result?.isOK ?? false }
    }

    /// Every lowercase key a password field answers to.
    private static let passwordKeys: Set<String> = [
        "password", "passwd", "pass", "pwd", "user_password", "new_password",
        "new-password", "password1", "password_confirm", "confirm_password",
        "password2", "password_confirmation", "repeat_password", "retype_password"
    ]

    /// Runs the full chain. `onStep` and `onFields` stream progress to the UI
    /// as it happens — fields land in the sheet while the run is still going.
    func run(
        url: String,
        method: String,
        person: Person?,
        wants2FA: Bool,
        onStep: @escaping (LiveRunStep) -> Void,
        onFields: @escaping ([FormField]) -> Void
    ) async -> Outcome {
        var outcome = Outcome()
        func emit(_ step: LiveRunStep) {
            outcome.steps.append(step)
            onStep(step)
        }

        let learning = FormLearningStore.shared
        let domain = learning.domain(for: url)

        // 1. The form automator runs first — discover the real fields.
        emit(LiveRunStep(title: "DISCOVER \(domain)", detail: url))
        guard case .success(let form) = await automation.discoverForm(pageURL: url) else {
            emit(LiveRunStep(title: "DISCOVER FAILED", detail: "No form found at the URL", isOK: false))
            return outcome
        }
        outcome.fields = form.fields
        onFields(form.fields)
        emit(LiveRunStep(title: "\(form.fields.count) FIELDS FOUND", detail: form.fields.map(\.name).joined(separator: ", ")))

        var values: [String: String] = person?.formValues ?? [:]
        var alias: EmailAlias?
        var password = ""

        // 2. A vault credential saved for this domain wins — imported CSV rows
        //    live here. Fill with the existing email/username/password instead
        //    of minting anything new.
        if let saved = CredentialVault.shared.match(domain),
           let savedPassword = KeychainService.password(account: "cred-\(saved.domain)"),
           !savedPassword.isEmpty {
            password = savedPassword
            if !saved.email.isEmpty {
                for key in ["email", "email_address", "emailaddress", "mail"] {
                    values[key] = saved.email
                }
            }
            if !saved.username.isEmpty {
                for key in ["username", "user_name", "login", "user"] {
                    values[key] = saved.username
                }
            }
            for key in Self.passwordKeys {
                values[key] = password
            }
            emit(LiveRunStep(title: "VAULT \(saved.domain)", detail: "\(saved.email) · \(saved.username) · saved password"))
        } else {
            // 2a. Email field detected → mint a fresh alias that forwards to the
            //     real inbox (the 2FA IMAP account). Falls back to roster/inbox.
            if EmailAliasService.shared.isConfigured, EmailAliasService.shared.settings.isEnabled {
                emit(LiveRunStep(title: "MINTING ALIAS", detail: "emailalias.io · label \(domain)"))
                do {
                    let created = try await EmailAliasService.shared.createAlias(label: domain)
                    alias = created
                    for key in ["email", "email_address", "emailaddress", "mail"] {
                        values[key] = created.aliasEmail
                    }
                    emit(LiveRunStep(title: "ALIAS \(created.aliasEmail)", detail: "forwards to \(created.destinationEmail)"))
                } catch {
                    let message = (error as? EmailAliasError)?.message ?? error.localizedDescription
                    emit(LiveRunStep(title: "ALIAS FAILED", detail: message + " — using roster/inbox email", isOK: false))
                }
            }
            if alias == nil, (values["email"] ?? "").isEmpty, EmailCodeService.shared.isConfigured {
                values["email"] = EmailCodeService.shared.settings.emailAddress
            }

            // 2b. Password fields detected → one generated strong password for
            //     password + confirm pairs.
            password = Self.generatePassword()
            for key in Self.passwordKeys {
                values[key] = password
            }
        }

        // 3. Username: roster/vault value, or derived from the alias/roster email.
        if (values["username"] ?? "").isEmpty {
            let source = alias?.aliasEmail ?? values["email"] ?? ""
            let localPart = source.split(separator: "@").first.map(String.init)
            if let localPart, !localPart.isEmpty {
                values["username"] = localPart
            }
        }

        let credential = GeneratedCredential(
            domain: domain,
            email: values["email"] ?? "",
            username: values["username"] ?? ""
        )

        // 5. Fill every discovered field (learned aliases as fallback).
        let overlay = FormAutomationService.applyValues(
            values,
            to: form.fields,
            aliases: learning.aliasMap(for: domain)
        )
        learning.learnAliases(domain: domain, mappings: overlay.matchedIdentifiers)
        outcome.fields = overlay.fields
        onFields(overlay.fields)
        let filledCount = overlay.matchedKeys.count + overlay.aliasApplied.count
        emit(LiveRunStep(title: "FILLED \(filledCount)/\(form.fields.count) FIELDS", detail: overlay.fields.filter { !$0.value.isEmpty }.map(\.name).joined(separator: ", ")))

        // 6. Submit over real HTTP.
        emit(LiveRunStep(title: "SUBMIT \(form.method) → \(domain)"))
        let submittedAt = Date()
        let result = await automation.submit(
            url: url,
            method: method.uppercased() == "GET" ? "GET" : form.method,
            fields: overlay.fields
        )
        outcome.result = result
        emit(LiveRunStep(
            title: result.isOK ? "SUBMITTED · HTTP \(result.statusCode)" : "SUBMIT FAILED",
            detail: result.isOK ? result.finalURL : (result.error ?? "HTTP \(result.statusCode)"),
            isOK: result.isOK
        ))

        // 7. Retrieve results: poll the real inbox — mail to the alias
        //    forwards there — for the verification code, then continue.
        var gotCode = false
        if wants2FA, result.isOK, EmailCodeService.shared.isConfigured {
            emit(LiveRunStep(
                title: "CHECKING INBOX",
                detail: EmailCodeService.shared.settings.emailAddress + (alias != nil ? " (alias forwards here)" : "")
            ))
            let startedAt = Date()
            do {
                let code = try await EmailCodeService.shared.waitForCode(after: submittedAt)
                outcome.code = code
                gotCode = true
                emit(LiveRunStep(title: "CODE \(code.code)", detail: "from \(code.from) · \(code.subject)"))
                TelemetryViewModel.shared.noteRouteActivity(
                    endpointName: "Email 2FA (IMAP)",
                    latencyMs: Date().timeIntervalSince(startedAt) * 1000,
                    success: true
                )
            } catch {
                let message = (error as? Email2FAError)?.message ?? error.localizedDescription
                emit(LiveRunStep(title: "NO CODE YET", detail: message, isOK: false))
                TelemetryViewModel.shared.noteRouteActivity(
                    endpointName: "Email 2FA (IMAP)",
                    latencyMs: Date().timeIntervalSince(startedAt) * 1000,
                    success: false
                )
            }
        } else if wants2FA, result.isOK {
            emit(LiveRunStep(title: "INBOX NOT CONFIGURED", detail: "Set the mailbox in Form Automation → envelope icon", isOK: false))
        }

        // 8. Store the credential (password Keychain-only) on success.
        if result.isOK, !credential.email.isEmpty {
            KeychainService.setPassword(password, account: "cred-\(domain)")
            Self.saveCredential(credential)
            outcome.credential = credential
            emit(LiveRunStep(title: "CREDENTIALS STORED", detail: "\(credential.email) · \(credential.username) · password in Keychain"))
        }

        let unmatched = values.keys
            .filter { !overlay.matchedKeys.contains($0) && !overlay.aliasApplied.contains($0) }
            .sorted()
        learning.record(
            FormLearningRecord(
                domain: domain,
                timestamp: Date(),
                mode: "live",
                submitOK: result.isOK,
                httpStatus: result.statusCode,
                matchedKeys: overlay.matchedKeys.sorted(),
                aliasApplied: overlay.aliasApplied.sorted(),
                unmatched: unmatched,
                missingRequired: overlay.fields.filter { $0.isRequired && $0.value.isEmpty }.map(\.name),
                got2FA: gotCode
            )
        )

        return outcome
    }

    /// List of stored live-run credentials, newest first.
    static func loadCredentials() -> [GeneratedCredential] {
        PersistenceStore.load([GeneratedCredential].self, forKey: credentialKey) ?? []
    }

    /// Remembers a credential row (password stays in the Keychain).
    static func saveCredential(_ credential: GeneratedCredential) {
        var all = loadCredentials()
        all.removeAll { $0.domain == credential.domain && $0.email == credential.email }
        all.insert(credential, at: 0)
        PersistenceStore.save(Array(all.prefix(40)), forKey: credentialKey)
    }

    /// Reads the run's password back from the Keychain.
    static func password(forDomain domain: String) -> String? {
        KeychainService.password(account: "cred-\(domain)")
    }

    /// Cryptographically random 16-char password (SystemRandomNumberGenerator
    /// is a secure RNG on Apple platforms). Ambiguous glyphs are excluded.
    nonisolated static func generatePassword(length: Int = 16) -> String {
        let characters = Array("ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789!@#%^&*")
        return String((0..<length).map { _ in characters[Int.random(in: 0..<characters.count)] })
    }
}
