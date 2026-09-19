//
//  Email2FASettingsView.swift
//  SparkAI
//
//  Mailbox connection sheet for automatic verification-code retrieval.
//  Connects over IMAP/TLS to the user's own email service; the app password
//  is stored in the Keychain only. Consumer mail providers require an
//  app-specific password (account → security → app passwords).
//

import SwiftUI

struct Email2FASettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var settings = EmailCodeService.shared.settings
    @State private var appPassword = ""
    @State private var hasPassword = EmailCodeService.shared.hasPassword
    @State private var isTesting = false
    @State private var statusLine: String?
    @State private var isStatusError = false

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 14) {
                    accountCard
                    passwordCard
                    connectionCard
                    disclosureCard
                }
                .padding(14)
                .padding(.bottom, 28)
            }
        }
        .background(Theme.bgPrimary.ignoresSafeArea())
        .onAppear { settings = EmailCodeService.shared.settings }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                Haptics.light()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(Theme.bgSurface, in: .rect(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("EMAIL 2FA")
                    .font(Theme.mono(13, .heavy))
                    .tracking(1.5)
                    .foregroundStyle(Theme.textPrimary)
                Text("IMAP · VERIFICATION CODES · KEYCHAIN")
                    .font(Theme.mono(9, .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.sky)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial.opacity(0.4))
    }

    // MARK: - Account

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ACCOUNT")
                .font(Theme.mono(9, .heavy))
                .tracking(1)
                .foregroundStyle(Theme.textTertiary)

            TextField("you@gmail.com", text: $settings.emailAddress)
                .font(Theme.mono(12.5))
                .foregroundStyle(Theme.textPrimary)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.bgElevated, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
                .onChange(of: settings.emailAddress) { oldValue, newValue in
                    // Auto-suggest the provider's IMAP host once.
                    if let hint = EmailCodeService.hostHint(forEmail: newValue),
                       EmailCodeService.hostHint(forEmail: oldValue) == nil || settings.imapHost.isEmpty {
                        settings.imapHost = hint
                        settings.imapPort = 993
                    }
                }

            HStack(spacing: 8) {
                TextField("imap.example.com", text: $settings.imapHost)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Theme.bgElevated, in: .rect(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))

                TextField(value: $settings.imapPort, format: .number.grouping(.never)) {
                    Text("993")
                }
                .font(Theme.mono(12))
                .foregroundStyle(Theme.textPrimary)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .frame(width: 72)
                .padding(.vertical, 8)
                .background(Theme.bgElevated, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            }

            TextField("Sender filter (optional, comma-separated)", text: $settings.senderFilter)
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Theme.bgElevated, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        }
        .padding(12)
        .background(Theme.bgSurface.opacity(0.92), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
    }

    // MARK: - App password

    private var passwordCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("APP PASSWORD")
                    .font(Theme.mono(9, .heavy))
                    .tracking(1)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                if hasPassword {
                    Label("STORED", systemImage: "checkmark.seal.fill")
                        .font(Theme.mono(8.5, .heavy))
                        .tracking(0.8)
                        .foregroundStyle(Theme.emerald)
                }
            }

            SecureField("Paste an app-specific password", text: $appPassword)
                .font(Theme.mono(12.5))
                .foregroundStyle(Theme.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.bgElevated, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))

            HStack(spacing: 8) {
                Button {
                    commitSave()
                } label: {
                    Text("SAVE")
                        .font(Theme.mono(10, .heavy))
                        .tracking(1)
                        .foregroundStyle(Theme.sky)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Theme.skyDim, in: .rect(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.sky.opacity(0.3)))
                }
                .disabled(appPassword.isEmpty)
                .opacity(appPassword.isEmpty ? 0.4 : 1)

                if hasPassword {
                    Button {
                        Haptics.medium()
                        EmailCodeService.shared.deletePassword()
                        hasPassword = EmailCodeService.shared.hasPassword
                        statusLine = "Password removed from Keychain"
                        isStatusError = false
                    } label: {
                        Text("CLEAR")
                            .font(Theme.mono(10, .heavy))
                            .tracking(1)
                            .foregroundStyle(Theme.rose)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Theme.rose.opacity(0.1), in: .rect(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.rose.opacity(0.3)))
                    }
                }
            }
        }
        .padding(12)
        .background(Theme.bgSurface.opacity(0.92), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
    }

    // MARK: - Connection test

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CONNECTION")
                .font(Theme.mono(9, .heavy))
                .tracking(1)
                .foregroundStyle(Theme.textTertiary)

            Button {
                Task { await test() }
            } label: {
                HStack(spacing: 6) {
                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Theme.sky)
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 11, weight: .bold))
                    }
                    Text(isTesting ? "CONNECTING…" : "TEST CONNECTION")
                        .font(Theme.mono(10.5, .heavy))
                        .tracking(1)
                }
                .foregroundStyle(isTesting ? Theme.textTertiary : Theme.sky)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Theme.skyDim, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.sky.opacity(0.3)))
            }
            .disabled(isTesting || !canTest)

            if let statusLine {
                Text(statusLine)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(isStatusError ? Theme.rose : Theme.emerald)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(Theme.bgSurface.opacity(0.92), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
    }

    // MARK: - Disclosure

    private var disclosureCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("HOW THIS WORKS")
                .font(Theme.mono(9, .heavy))
                .tracking(1)
                .foregroundStyle(Theme.amber)
            Text("Spark connects directly to your mailbox over IMAP + TLS and reads recent messages to pull verification codes after a sign-up submit. Gmail, iCloud and Outlook require an app-specific password (account → security → app passwords; 2-step verification must be on). The password lives in your device Keychain — nothing is sent to any cloud service, and only code-bearing messages are read.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Theme.amber.opacity(0.07), in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.amber.opacity(0.28)))
    }

    // MARK: - Actions

    private var canTest: Bool {
        !settings.emailAddress.isEmpty && !settings.imapHost.isEmpty && hasPassword
    }

    private func commitSave() {
        Haptics.light()
        EmailCodeService.shared.update(settings)
        if !appPassword.isEmpty {
            EmailCodeService.shared.savePassword(appPassword)
            appPassword = ""
        }
        hasPassword = EmailCodeService.shared.hasPassword
        statusLine = "Settings saved"
        isStatusError = false
    }

    private func test() async {
        commitSave()
        isTesting = true
        statusLine = nil
        defer { isTesting = false }
        do {
            Haptics.light()
            let summary = try await EmailCodeService.shared.testConnection()
            statusLine = summary
            isStatusError = false
        } catch {
            Haptics.medium()
            statusLine = (error as? Email2FAError)?.message ?? error.localizedDescription
            isStatusError = true
        }
    }
}
