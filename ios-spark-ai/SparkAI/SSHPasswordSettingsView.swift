//
//  SSHPasswordSettingsView.swift
//  SparkAI
//
//  Settings sheet for the flak3dd SSH credentials. Host, port, username
//  are stored on-device; the SSH password lives in the Keychain only.
//  A "Test Connection" button does a lightweight TCP probe (banner read)
//  to verify the host is reachable and running an SSH daemon.
//

import SwiftUI

struct SSHPasswordSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var settings = SSHPasswordService.shared.settings
    @State private var sshPassword = ""
    @State private var hasPassword = SSHPasswordService.shared.hasPassword
    @State private var isTesting = false
    @State private var statusLine: String?
    @State private var isStatusError = false

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 14) {
                    hostCard
                    passwordCard
                    connectionCard
                    disclosureCard
                }
                .padding(14)
                .padding(.bottom, 28)
            }
        }
        .background(Theme.bgPrimary.ignoresSafeArea())
        .onAppear { settings = SSHPasswordService.shared.settings }
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
                Text("SSH PASSWORD")
                    .font(Theme.mono(13, .heavy))
                    .tracking(1.5)
                    .foregroundStyle(Theme.textPrimary)
                Text("FLAK3DD · SSH · KEYCHAIN")
                    .font(Theme.mono(9, .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.amber)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial.opacity(0.4))
    }

    // MARK: - Host + credentials

    private var hostCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CONNECTION")
                .font(Theme.mono(9, .heavy))
                .tracking(1)
                .foregroundStyle(Theme.textTertiary)

            TextField("spark-mirror.flak3dd.dev", text: $settings.host)
                .font(Theme.mono(12.5))
                .foregroundStyle(Theme.textPrimary)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.bgElevated, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))

            HStack(spacing: 8) {
                TextField("username", text: $settings.username)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Theme.bgElevated, in: .rect(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))

                TextField(value: $settings.port, format: .number.grouping(.never)) {
                    Text("22")
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

            TextField("Label (e.g. flak3dd)", text: $settings.label)
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

    // MARK: - SSH password

    private var passwordCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SSH PASSWORD")
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

            SecureField("Paste SSH password", text: $sshPassword)
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
                .disabled(sshPassword.isEmpty)
                .opacity(sshPassword.isEmpty ? 0.4 : 1)

                if hasPassword {
                    Button {
                        Haptics.medium()
                        SSHPasswordService.shared.deletePassword()
                        hasPassword = SSHPasswordService.shared.hasPassword
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
            Text("TEST")
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
                            .tint(Theme.amber)
                    } else {
                        Image(systemName: "terminal")
                            .font(.system(size: 11, weight: .bold))
                    }
                    Text(isTesting ? "CONNECTING…" : "TEST CONNECTION")
                        .font(Theme.mono(10.5, .heavy))
                        .tracking(1)
                }
                .foregroundStyle(isTesting ? Theme.textTertiary : Theme.amber)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Theme.amber.opacity(0.1), in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.amber.opacity(0.3)))
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
            Text("Stores SSH credentials for your flak3dd server. The password is kept exclusively in the device Keychain — it never appears in backups, logs or any cloud sync. During live runs or sandbox commands, Spark can inject these credentials to connect via SSH. The connection test performs a TCP probe to verify the host is reachable and returns an SSH banner; it does not authenticate.")
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
        !settings.host.isEmpty && hasPassword
    }

    private func commitSave() {
        Haptics.light()
        SSHPasswordService.shared.update(settings)
        if !sshPassword.isEmpty {
            SSHPasswordService.shared.savePassword(sshPassword)
            sshPassword = ""
        }
        hasPassword = SSHPasswordService.shared.hasPassword
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
            let summary = try await SSHPasswordService.shared.testConnection()
            statusLine = summary
            isStatusError = false
        } catch {
            Haptics.medium()
            statusLine = (error as? SSHError)?.message ?? error.localizedDescription
            isStatusError = true
        }
    }
}
