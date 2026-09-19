//
//  CredentialsView.swift
//  SparkAI
//
//  Credential vault sheet: import a CSV of site credentials (template
//  provided), browse saved rows and copy a password back out of the
//  Keychain. Passwords never persist anywhere but the Keychain.
//

import SwiftUI
import UniformTypeIdentifiers

struct CredentialsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var credentials: [SiteCredential] = []
    @State private var showImporter = false
    @State private var statusLine: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 14) {
                    templateCard
                    importCard
                    if !credentials.isEmpty {
                        vaultSection
                    }
                }
                .padding(14)
                .padding(.bottom, 28)
            }
        }
        .background(Theme.bgPrimary.ignoresSafeArea())
        .onAppear { credentials = CredentialVault.shared.credentials }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.commaSeparatedText, .plainText, .data],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
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
                Text("CREDENTIAL VAULT")
                    .font(Theme.mono(13, .heavy))
                    .tracking(1.5)
                    .foregroundStyle(Theme.textPrimary)
                Text("CSV IMPORT · KEYCHAIN PASSWORDS")
                    .font(Theme.mono(9, .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.emerald)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial.opacity(0.4))
    }

    // MARK: - Template

    private var templateCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TEMPLATE CSV")
                .font(Theme.mono(9, .heavy))
                .tracking(1)
                .foregroundStyle(Theme.textTertiary)

            Text(CredentialVault.templateCSV)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(hex: 0x0C0C10), in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))

            HStack(spacing: 8) {
                Button {
                    UIPasteboard.general.string = CredentialVault.templateCSV
                    Haptics.light()
                    statusLine = "Template copied to clipboard"
                } label: {
                    Label("COPY", systemImage: "doc.on.doc")
                        .font(Theme.mono(10, .heavy))
                        .tracking(0.8)
                        .foregroundStyle(Theme.sky)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Theme.skyDim, in: .rect(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.sky.opacity(0.3)))
                }

                ShareLink(item: CredentialVault.templateCSV, preview: SharePreview("spark-credentials-template.csv")) {
                    Label("SHARE", systemImage: "square.and.arrow.up")
                        .font(Theme.mono(10, .heavy))
                        .tracking(0.8)
                        .foregroundStyle(Theme.sky)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Theme.skyDim, in: .rect(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.sky.opacity(0.3)))
                }
            }
        }
        .padding(12)
        .background(Theme.bgSurface.opacity(0.92), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
    }

    // MARK: - Import

    private var importCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("IMPORT")
                .font(Theme.mono(9, .heavy))
                .tracking(1)
                .foregroundStyle(Theme.textTertiary)

            Button {
                Haptics.light()
                showImporter = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 11, weight: .bold))
                    Text("UPLOAD CREDENTIALS CSV")
                        .font(Theme.mono(10.5, .heavy))
                        .tracking(1)
                }
                .foregroundStyle(Theme.emerald)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Theme.emeraldDim, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.emerald.opacity(0.3)))
            }

            Text("Header row required (url, username, email, password). Passwords are moved into the Keychain the moment the file lands — the CSV itself is never saved. When a live run's form domain matches a row here, it fills the saved email, username and password instead of minting a fresh alias.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let statusLine {
                Text(statusLine)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(statusLine.hasPrefix("Imported") ? Theme.emerald : Theme.amber)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(Theme.bgSurface.opacity(0.92), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
    }

    // MARK: - Vault

    private var vaultSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("VAULT (\(credentials.count))")
                    .font(Theme.mono(9, .heavy))
                    .tracking(1)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button {
                    Haptics.medium()
                    CredentialVault.shared.clear()
                    credentials = CredentialVault.shared.credentials
                    statusLine = "Vault cleared — Keychain passwords deleted"
                } label: {
                    Text("CLEAR ALL")
                        .font(Theme.mono(9, .heavy))
                        .tracking(0.8)
                        .foregroundStyle(Theme.rose)
                }
            }

            ForEach(credentials) { credential in
                vaultRow(credential)
            }
        }
    }

    private func vaultRow(_ credential: SiteCredential) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.sky)
                Text(credential.domain)
                    .font(Theme.mono(11.5, .heavy))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    UIPasteboard.general.string = CredentialVault.shared.password(for: credential)
                    Haptics.light()
                } label: {
                    Label("PASSWORD", systemImage: "lock.open")
                        .font(Theme.mono(9, .heavy))
                        .tracking(0.6)
                        .foregroundStyle(Theme.sky)
                }
                Button {
                    Haptics.medium()
                    CredentialVault.shared.remove(credential.id)
                    credentials = CredentialVault.shared.credentials
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            if !credential.email.isEmpty || !credential.username.isEmpty {
                Text([credential.email, credential.username].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(10)
        .background(Color(hex: 0x0C0C10), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }

    // MARK: - Actions

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            statusLine = "Could not read the file as text"
            Haptics.medium()
            return
        }
        let added = CredentialVault.shared.importCSV(text)
        credentials = CredentialVault.shared.credentials
        if added > 0 {
            Haptics.medium()
            statusLine = "Imported \(added) credential\(added == 1 ? "" : "s") · passwords in Keychain"
        } else {
            statusLine = "No valid rows — need a header with url + password columns"
            Haptics.medium()
        }
    }
}
