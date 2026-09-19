//
//  EmailAliasSettingsView.swift
//  SparkAI
//
//  Configuration for the emailalias.io alias source used by live runs:
//  enable/disable, API key management (Keychain-only) and connection test.
//  Aliases forward to the account's verified primary inbox — the same inbox
//  Email 2FA polls over IMAP — so the target site never sees the real address.
//

import SwiftUI

struct EmailAliasSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var apiKey = ""
    @State private var isEnabled = EmailAliasService.shared.settings.isEnabled
    @State private var labelPrefix = EmailAliasService.shared.settings.labelPrefix
    @State private var hasKey = EmailAliasService.shared.hasAPIKey
    @State private var isTesting = false
    @State private var statusLine: String?
    @State private var isStatusOK = false

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 14) {
                    accountCard
                    keyCard
                    testButton
                    if let statusLine {
                        Text(statusLine)
                            .font(Theme.mono(10.5))
                            .foregroundStyle(isStatusOK ? Theme.emerald : Theme.rose)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    disclosure
                }
                .padding(14)
                .padding(.bottom, 28)
            }
        }
        .background(Theme.bgPrimary.ignoresSafeArea())
        .onAppear { hasKey = EmailAliasService.shared.hasAPIKey }
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
                Text("EMAIL ALIAS")
                    .font(Theme.mono(13, .heavy))
                    .tracking(1.5)
                    .foregroundStyle(Theme.textPrimary)
                Text("EMAILALIAS.IO · FORWARDING")
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
        VStack(alignment: .leading, spacing: 10) {
            Text("ACCOUNT")
                .font(Theme.mono(9, .heavy))
                .tracking(1)
                .foregroundStyle(Theme.textTertiary)

            Toggle(isOn: $isEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("USE ALIASES IN LIVE RUNS")
                        .font(Theme.mono(11, .heavy))
                        .tracking(0.8)
                        .foregroundStyle(Theme.textSecondary)
                    Text(hasKey ? "A fresh alias is minted per email field" : "Requires an API key")
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .tint(Theme.emerald)
            .onChange(of: isEnabled) { _, newValue in
                commitSettings()
            }

            TextField("label prefix (optional, e.g. spark)", text: $labelPrefix)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.bgElevated, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
                .onSubmit { commitSettings() }

            Text("Aliases forward to your verified primary inbox on emailalias.io — the site only ever sees the alias.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Theme.bgSurface.opacity(0.92), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
    }

    // MARK: - API key

    private var keyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("API KEY")
                    .font(Theme.mono(9, .heavy))
                    .tracking(1)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                if hasKey {
                    Label("STORED", systemImage: "lock.fill")
                        .font(Theme.mono(8.5, .heavy))
                        .tracking(0.8)
                        .foregroundStyle(Theme.emerald)
                }
            }

            SecureField("ea_live_…", text: $apiKey)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.bgElevated, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))

            HStack(spacing: 14) {
                Button {
                    saveKey()
                } label: {
                    Text("SAVE KEY")
                        .font(Theme.mono(10, .heavy))
                        .tracking(1)
                        .foregroundStyle(Theme.sky)
                }
                .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)

                if hasKey {
                    Button(role: .destructive) {
                        EmailAliasService.shared.deleteAPIKey()
                        hasKey = false
                        statusLine = "API key removed"
                        isStatusOK = false
                        Haptics.medium()
                    } label: {
                        Text("CLEAR KEY")
                            .font(Theme.mono(10, .heavy))
                            .tracking(1)
                            .foregroundStyle(Theme.rose)
                    }
                }
                Spacer()
            }
        }
        .padding(12)
        .background(Theme.bgSurface.opacity(0.92), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
    }

    private func saveKey() {
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        EmailAliasService.shared.saveAPIKey(key)
        hasKey = EmailAliasService.shared.hasAPIKey
        apiKey = ""
        statusLine = "Key stored in the Keychain — run TEST CONNECTION to verify"
        isStatusOK = true
        Haptics.medium()
    }

    // MARK: - Test

    private var testButton: some View {
        Button {
            Task { await test() }
        } label: {
            HStack(spacing: 6) {
                if isTesting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.sky)
                } else {
                    Image(systemName: "bolt.horizontal")
                        .font(.system(size: 11, weight: .bold))
                }
                Text(isTesting ? "TESTING…" : "TEST CONNECTION")
                    .font(Theme.mono(10.5, .heavy))
                    .tracking(1)
            }
            .foregroundStyle(isTesting ? Theme.textTertiary : Theme.sky)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(Theme.skyDim, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.sky.opacity(0.3)))
        }
        .disabled(isTesting || !hasKey)
        .opacity(hasKey ? 1 : 0.45)
    }

    private func test() async {
        isTesting = true
        statusLine = nil
        defer { isTesting = false }
        do {
            let message = try await EmailAliasService.shared.testConnection()
            Haptics.light()
            statusLine = message
            isStatusOK = true
        } catch {
            Haptics.medium()
            statusLine = (error as? EmailAliasError)?.message ?? error.localizedDescription
            isStatusOK = false
        }
    }

    private func commitSettings() {
        EmailAliasService.shared.update(
            EmailAliasSettings(isEnabled: isEnabled, labelPrefix: labelPrefix)
        )
    }

    // MARK: - Disclosure

    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("HOW THIS WORKS")
                .font(Theme.mono(9, .heavy))
                .tracking(1)
                .foregroundStyle(Theme.amber)

            Text("During a live run, when an email field is found Spark mints a random alias on emailalias.io and enters it instead of your real address. Mail to the alias forwards to your account's primary inbox — the same mailbox Email 2FA reads over IMAP — so verification codes still reach you while the site only knows the alias. The REST API is a Premium feature: create the ea_live_ key at emailalias.io → Settings → API Keys (shown once). The key lives in your device Keychain only.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Theme.amber.opacity(0.07), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.amber.opacity(0.28)))
    }
}
