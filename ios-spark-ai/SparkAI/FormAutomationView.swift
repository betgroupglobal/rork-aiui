//
//  FormAutomationView.swift
//  SparkAI
//
//  Website sign-up form automation sheet: discover a page's form fields,
//  fill values (secure fields masked), submit over real HTTP and inspect the
//  response. Templates persist locally for repeat runs.
//

import SwiftUI

struct FormAutomationView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var service = FormAutomationService()
    @State private var urlString = ""
    @State private var method = "POST"
    @State private var fields: [FormField] = []
    @State private var newFieldName = ""
    @State private var isDiscovering = false
    @State private var isSubmitting = false
    @State private var statusLine: String?
    @State private var lastResult: FormSubmitResult?
    @State private var presets: [FormSpec] = []
    @State private var showSaveAlert = false
    @State private var presetName = ""
    @State private var showPeople = false
    @State private var showEmail2FA = false
    @State private var people: [Person] = []
    @AppStorage("form-2fa-autofetch") private var waitForCode = true
    @State private var isWaitingCode = false
    @State private var fetchedCode: VerificationCode?
    @State private var codeStatusLine: String?
    @State private var showEmailAlias = false
    @State private var isLiveRunning = false
    @State private var liveSteps: [LiveRunStep] = []
    @State private var liveCredential: GeneratedCredential?
    @State private var showCredentials = false

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 14) {
                    if !presets.isEmpty {
                        presetsRow
                    }
                    targetCard
                    fieldsCard
                    submitButton
                    assistantsCard
                    learningCard
                    if isLiveRunning || !liveSteps.isEmpty {
                        liveRunCard
                    }
                    if let lastResult {
                        resultCard(lastResult)
                    }
                    if isWaitingCode {
                        waitingCard
                    }
                    if let fetchedCode {
                        codeBanner(fetchedCode)
                    }
                    if let codeStatusLine {
                        Text(codeStatusLine)
                            .font(Theme.mono(10.5))
                            .foregroundStyle(Theme.rose)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(14)
                .padding(.bottom, 28)
            }
        }
        .background(Theme.bgPrimary.ignoresSafeArea())
        .onAppear {
            presets = service.loadPresets()
            people = PeopleStore.shared.people
        }
        .alert("Save template", isPresented: $showSaveAlert) {
            TextField("Template name", text: $presetName)
            Button("Save") { commitSavePreset() }
            Button("Cancel", role: .cancel) { presetName = "" }
        } message: {
            Text("Stores the target URL, method and all field values on this device.")
        }
        .sheet(isPresented: $showPeople, onDismiss: { people = PeopleStore.shared.people }) {
            PeopleView(onApply: { applyPerson($0) })
        }
        .sheet(isPresented: $showEmail2FA) {
            Email2FASettingsView()
        }
        .sheet(isPresented: $showEmailAlias) {
            EmailAliasSettingsView()
        }
        .sheet(isPresented: $showCredentials) {
            CredentialsView()
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
                Text("FORM AUTOMATION")
                    .font(Theme.mono(13, .heavy))
                    .tracking(1.5)
                    .foregroundStyle(Theme.textPrimary)
                Text("SIGN-UP FLOWS · LIVE HTTP")
                    .font(Theme.mono(9, .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.sky)
            }

            Spacer()

            Button {
                Haptics.light()
                Task { await runLive() }
            } label: {
                ZStack {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(isLiveRunning ? Theme.amber : Theme.blue)
                        .opacity(isLiveRunning ? 0.25 : 1)
                    if isLiveRunning {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(Theme.amber)
                    }
                }
                .frame(width: 32, height: 32)
                .background(Theme.blueDim, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.blue.opacity(0.3)))
            }
            .disabled(isLiveRunning || isSubmitting || urlString.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(urlString.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)

            Button {
                Haptics.light()
                showEmail2FA = true
            } label: {
                Image(systemName: "envelope.badge")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(EmailCodeService.shared.isConfigured ? Theme.sky : Theme.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(Theme.bgSurface, in: .rect(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
                    .overlay(alignment: .topTrailing) {
                        if EmailCodeService.shared.isConfigured {
                            Circle()
                                .fill(Theme.emerald)
                                .frame(width: 7, height: 7)
                                .offset(x: 3, y: -3)
                        }
                    }
            }

            Button {
                Haptics.light()
                showPeople = true
            } label: {
                Image(systemName: "person.2")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(people.isEmpty ? Theme.textSecondary : Theme.sky)
                    .frame(width: 32, height: 32)
                    .background(Theme.bgSurface, in: .rect(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
            }

            Button {
                Haptics.light()
                showCredentials = true
            } label: {
                Image(systemName: "key.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(CredentialVault.shared.credentials.isEmpty ? Theme.textSecondary : Theme.emerald)
                    .frame(width: 32, height: 32)
                    .background(Theme.bgSurface, in: .rect(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
                    .overlay(alignment: .topTrailing) {
                        if !CredentialVault.shared.credentials.isEmpty {
                            Circle()
                                .fill(Theme.emerald)
                                .frame(width: 7, height: 7)
                                .offset(x: 3, y: -3)
                        }
                    }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial.opacity(0.4))
    }

    // MARK: - Templates

    private var presetsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("TEMPLATES")
                    .font(Theme.mono(9, .heavy))
                    .tracking(1)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button {
                    Haptics.light()
                    showSaveAlert = true
                } label: {
                    Label("SAVE", systemImage: "square.and.arrow.down")
                        .font(Theme.mono(9, .heavy))
                        .tracking(0.8)
                        .foregroundStyle(Theme.sky)
                }
                .disabled(urlString.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(urlString.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(presets) { preset in
                        Button {
                            loadPreset(preset)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "doc.text.magnifyingglass")
                                    .font(.system(size: 10, weight: .semibold))
                                Text(preset.name)
                                    .font(Theme.mono(11, .semibold))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Theme.bgSurface, in: .capsule)
                            .overlay(Capsule().strokeBorder(Theme.border))
                        }
                        .contextMenu {
                            Button("Delete template", role: .destructive) {
                                Haptics.medium()
                                service.deletePreset(preset.id)
                                presets = service.loadPresets()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Target

    private var targetCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("TARGET")
                    .font(Theme.mono(9, .heavy))
                    .tracking(1)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Picker("Method", selection: $method) {
                    Text("POST").tag("POST")
                    Text("GET").tag("GET")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 132)
            }

            TextField("https://example.com/signup", text: $urlString)
                .font(Theme.mono(12.5))
                .foregroundStyle(Theme.textPrimary)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.bgElevated, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))

            Button {
                Task { await discover() }
            } label: {
                HStack(spacing: 6) {
                    if isDiscovering {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Theme.sky)
                    } else {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11, weight: .bold))
                    }
                    Text(isDiscovering ? "FETCHING…" : "DISCOVER FIELDS")
                        .font(Theme.mono(10.5, .heavy))
                        .tracking(1)
                }
                .foregroundStyle(isDiscovering ? Theme.textTertiary : Theme.sky)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Theme.skyDim, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.sky.opacity(0.3)))
            }
            .disabled(isDiscovering || isSubmitting || urlString.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(urlString.trimmingCharacters(in: .whitespaces).isEmpty ? 0.45 : 1)

            if let statusLine {
                Text(statusLine)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.amber)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(Theme.bgSurface.opacity(0.92), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
    }

    // MARK: - Fields

    private var fieldsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("FIELDS (\(fields.count))")
                    .font(Theme.mono(9, .heavy))
                    .tracking(1)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                if !fields.isEmpty {
                    Button {
                        Haptics.light()
                        withAnimation(.snappy(duration: 0.2)) { fields.removeAll() }
                    } label: {
                        Text("CLEAR")
                            .font(Theme.mono(9, .heavy))
                            .tracking(0.8)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }

            if fields.isEmpty {
                Text("Tap DISCOVER FIELDS to pull the real form from the page, or add custom field names below.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }

            ForEach(fields.indices, id: \.self) { index in
                fieldRow(index: index)
            }

            HStack(spacing: 8) {
                TextField("custom field name", text: $newFieldName)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Theme.bgElevated, in: .rect(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                    .onSubmit { addManualField() }

                Button {
                    addManualField()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.sky)
                        .frame(width: 36, height: 36)
                        .background(Theme.skyDim, in: .rect(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.sky.opacity(0.3)))
                }
                .disabled(newFieldName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .background(Theme.bgSurface.opacity(0.92), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
    }

    private func fieldRow(index: Int) -> some View {
        let field = fields[index]
        let isPassword = field.type.contains("password")

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(field.name)
                    .font(Theme.mono(10.5, .semibold))
                    .foregroundStyle(Theme.sky)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if !field.type.isEmpty, field.type != "text" {
                    Text(field.type.uppercased())
                        .font(Theme.mono(8, .heavy))
                        .tracking(0.6)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Theme.bgActive, in: .capsule)
                }

                if field.isRequired {
                    Text("REQ")
                        .font(Theme.mono(8, .heavy))
                        .tracking(0.6)
                        .foregroundStyle(Theme.rose)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Theme.rose.opacity(0.12), in: .capsule)
                }

                Spacer(minLength: 4)

                Button {
                    Haptics.light()
                    _ = fields.remove(at: index)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            let identifiers: [String] = [
                field.htmlID.isEmpty ? nil : "#\(field.htmlID)",
                field.labelText.isEmpty ? nil : "label: \(field.labelText)",
                field.ariaLabel.isEmpty ? nil : "aria: \(field.ariaLabel)",
                field.autocomplete.isEmpty ? nil : "auto: \(field.autocomplete)",
            ].compactMap { $0 }
            if !identifiers.isEmpty {
                Text(identifiers.joined(separator: " · "))
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Group {
                if isPassword {
                    SecureField(
                        field.placeholder.isEmpty ? "value" : field.placeholder,
                        text: $fields[index].value
                    )
                } else {
                    TextField(
                        field.placeholder.isEmpty ? "value" : field.placeholder,
                        text: $fields[index].value
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }
            }
            .font(Theme.mono(12.5))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Theme.bgElevated, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))

            if !field.options.isEmpty {
                Text("options: \(field.options.prefix(6).joined(separator: " · "))")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .background(Color(hex: 0x0C0C10), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }

    // MARK: - Submit

    private var canSubmit: Bool {
        !urlString.trimmingCharacters(in: .whitespaces).isEmpty && !fields.isEmpty
    }

    private var submitButton: some View {
        Button {
            Task { await submit() }
        } label: {
            HStack(spacing: 8) {
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 12, weight: .bold))
                }
                Text(isSubmitting ? "SUBMITTING…" : "SUBMIT FORM")
                    .font(Theme.mono(12, .heavy))
                    .tracking(1.5)
            }
            .foregroundStyle(canSubmit && !isSubmitting ? .white : Theme.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(canSubmit && !isSubmitting ? Theme.blue : Theme.bgSurface, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
        }
        .disabled(!canSubmit || isSubmitting)
    }

    private func resultCard(_ result: FormSubmitResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: result.isOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(result.isOK ? Theme.emerald : Theme.rose)
                Text(result.isOK ? "SUBMITTED · HTTP \(result.statusCode)" : "FAILED · \(result.error ?? "HTTP \(result.statusCode)")")
                    .font(Theme.mono(10, .heavy))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer()
                Text("\(result.durationMs)MS")
                    .font(Theme.mono(9, .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }

            Text(result.finalURL)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            if !result.snippet.isEmpty {
                Text(result.snippet)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(14)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(Color(hex: 0x0C0C10), in: .rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(result.isOK ? Theme.emerald.opacity(0.25) : Theme.rose.opacity(0.35))
        )
    }

    // MARK: - Assistants (people + 2FA)

    private var assistantsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ASSIST")
                .font(Theme.mono(9, .heavy))
                .tracking(1)
                .foregroundStyle(Theme.textTertiary)

            HStack(spacing: 8) {
                Image(systemName: "person.2")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.sky)
                Text("PEOPLE")
                    .font(Theme.mono(10.5, .heavy))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                if people.isEmpty {
                    Button {
                        Haptics.light()
                        showPeople = true
                    } label: {
                        Text("IMPORT CSV")
                            .font(Theme.mono(9, .heavy))
                            .tracking(0.8)
                            .foregroundStyle(Theme.sky)
                    }
                } else {
                    Menu {
                        ForEach(people) { person in
                            Button(person.displayName) {
                                Haptics.light()
                                applyPerson(person)
                            }
                        }
                    } label: {
                        Label("FILL", systemImage: "arrow.down.to.line")
                            .font(Theme.mono(9, .heavy))
                            .tracking(0.8)
                            .foregroundStyle(Theme.emerald)
                    }

                    Button {
                        Haptics.light()
                        showPeople = true
                    } label: {
                        Text("MANAGE")
                            .font(Theme.mono(9, .heavy))
                            .tracking(0.8)
                            .foregroundStyle(Theme.sky)
                    }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "envelope.badge")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(EmailCodeService.shared.isConfigured ? Theme.sky : Theme.textTertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("EMAIL 2FA CODE")
                        .font(Theme.mono(10.5, .heavy))
                        .tracking(0.8)
                        .foregroundStyle(Theme.textSecondary)
                    Text(EmailCodeService.shared.isConfigured ? EmailCodeService.shared.settings.emailAddress : "Not configured")
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Toggle("", isOn: $waitForCode)
                    .labelsHidden()
                    .disabled(!EmailCodeService.shared.isConfigured)
                Button {
                    Haptics.light()
                    showEmail2FA = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "at.badge.plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(EmailAliasService.shared.isConfigured ? Theme.sky : Theme.textTertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("EMAIL ALIAS")
                        .font(Theme.mono(10.5, .heavy))
                        .tracking(0.8)
                        .foregroundStyle(Theme.textSecondary)
                    Text(aliasStatusLine)
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { EmailAliasService.shared.settings.isEnabled },
                    set: { newValue in
                        var settings = EmailAliasService.shared.settings
                        settings.isEnabled = newValue
                        EmailAliasService.shared.update(settings)
                    }
                ))
                .labelsHidden()
                .disabled(!EmailAliasService.shared.isConfigured)
                Button {
                    Haptics.light()
                    showEmailAlias = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CredentialVault.shared.credentials.isEmpty ? Theme.textTertiary : Theme.emerald)
                VStack(alignment: .leading, spacing: 1) {
                    Text("SAVED CREDENTIALS")
                        .font(Theme.mono(10.5, .heavy))
                        .tracking(0.8)
                        .foregroundStyle(Theme.textSecondary)
                    Text(vaultStatusLine)
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if !CredentialVault.shared.credentials.isEmpty {
                    Text("\(CredentialVault.shared.credentials.count) SITES")
                        .font(Theme.mono(9, .heavy))
                        .tracking(0.8)
                        .foregroundStyle(Theme.emerald)
                }
                Button {
                    Haptics.light()
                    showCredentials = true
                } label: {
                    Text(CredentialVault.shared.credentials.isEmpty ? "IMPORT CSV" : "MANAGE")
                        .font(Theme.mono(9, .heavy))
                        .tracking(0.8)
                        .foregroundStyle(Theme.sky)
                }
            }
        }
        .padding(12)
        .background(Theme.bgSurface.opacity(0.92), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
    }

    // MARK: - Learning loop

    private var learningCard: some View {
        let learning = FormLearningStore.shared
        let summary = learning.summary(for: learning.domain(for: urlString))
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("LEARNING LOOP")
                    .font(Theme.mono(9, .heavy))
                    .tracking(1)
                    .foregroundStyle(Theme.emerald)
                Spacer()
                if !learning.records.isEmpty {
                    Button {
                        Haptics.medium()
                        learning.clear()
                    } label: {
                        Text("CLEAR")
                            .font(Theme.mono(9, .heavy))
                            .tracking(0.8)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }

            if let summary {
                Text(summary)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Text("Every submit — here or via the agent's signup_form — records outcomes and learns which field identifiers match. Learned mappings are re-applied on future runs and fed into the agent prompt.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Theme.emeraldDim, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.emerald.opacity(0.22)))
    }

    // MARK: - 2FA results

    private var waitingCard: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(Theme.amber)
            Text("CHECKING INBOX FOR VERIFICATION EMAIL…")
                .font(Theme.mono(10, .heavy))
                .tracking(0.8)
                .foregroundStyle(Theme.amber)
            Spacer()
        }
        .padding(12)
        .background(Theme.amber.opacity(0.07), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.amber.opacity(0.28)))
    }

    private func codeBanner(_ code: VerificationCode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("2FA CODE RECEIVED")
                    .font(Theme.mono(9, .heavy))
                    .tracking(1)
                    .foregroundStyle(Theme.emerald)
                Spacer()
                Button {
                    UIPasteboard.general.string = code.code
                    Haptics.light()
                } label: {
                    Label("COPY", systemImage: "doc.on.doc")
                        .font(Theme.mono(9, .heavy))
                        .tracking(0.8)
                        .foregroundStyle(Theme.sky)
                }
            }

            Text(code.code)
                .font(Theme.mono(28, .heavy))
                .tracking(5)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)

            Text("from: \(code.from) · \(code.subject)")
                .font(Theme.mono(9.5))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(12)
        .background(Theme.emeraldDim, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.emerald.opacity(0.35)))
    }

    // MARK: - Actions

    private func discover() async {
        isDiscovering = true
        statusLine = nil
        defer { isDiscovering = false }

        switch await service.discoverForm(pageURL: urlString) {
        case .success(let form):
            Haptics.light()
            method = form.method
            // Re-apply typed values by any shared identifier (name, id, label…).
            var typed: [String: String] = [:]
            for previous in fields where !previous.value.isEmpty {
                for key in FormAutomationService.identifierKeys(for: previous) {
                    typed[key] = previous.value
                }
            }
            let merged = FormAutomationService.applyValues(typed, to: form.fields).fields
            withAnimation(.snappy(duration: 0.25)) { fields = merged }
            statusLine = "Discovered \(merged.count) field\(merged.count == 1 ? "" : "s")"

        case .failure(let message):
            Haptics.medium()
            statusLine = message
        }
    }

    private func submit() async {
        isSubmitting = true
        lastResult = nil
        fetchedCode = nil
        codeStatusLine = nil
        let submittedAt = Date()
        let result = await service.submit(url: urlString, method: method, fields: fields)
        isSubmitting = false
        Haptics.medium()
        withAnimation(.snappy(duration: 0.25)) { lastResult = result }

        var got2FA = false
        if result.isOK, waitForCode, EmailCodeService.shared.isConfigured {
            isWaitingCode = true
            do {
                let code = try await EmailCodeService.shared.waitForCode(after: submittedAt)
                fetchedCode = code
                got2FA = true
                Haptics.medium()
            } catch {
                codeStatusLine = "2FA: \((error as? Email2FAError)?.message ?? error.localizedDescription)"
            }
            isWaitingCode = false
        }

        FormLearningStore.shared.record(
            FormLearningRecord(
                domain: FormLearningStore.shared.domain(for: urlString),
                timestamp: Date(),
                mode: "manual",
                submitOK: result.isOK,
                httpStatus: result.statusCode,
                matchedKeys: [],
                aliasApplied: [],
                unmatched: [],
                missingRequired: fields.filter { $0.isRequired && $0.value.isEmpty }.map(\.name),
                got2FA: got2FA
            )
        )
    }

    /// Drops a person's details into every matching field on the current form.
    private func applyPerson(_ person: Person) {
        guard !fields.isEmpty else { return }
        let overlay = FormAutomationService.applyValues(person.formValues, to: fields)
        withAnimation(.snappy(duration: 0.2)) { fields = overlay.fields }
        statusLine = "Filled from \(person.displayName)"
    }

    // MARK: - Live run

    private var aliasStatusLine: String {
        let service = EmailAliasService.shared
        guard service.isConfigured else { return "Not configured" }
        return service.settings.isEnabled ? "emailalias.io · enabled" : "emailalias.io · off"
    }

    private var vaultStatusLine: String {
        let vault = CredentialVault.shared
        guard !vault.credentials.isEmpty else { return "CSV import · passwords stay in Keychain" }
        let domain = FormLearningStore.shared.domain(for: urlString)
        if vault.match(domain) != nil {
            return "Match for \(domain) · live run reuses it"
        }
        return "\(vault.credentials.count) sites · reused on domain match"
    }

    private var liveRunCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.blue)
                Text("LIVE RUN")
                    .font(Theme.mono(9, .heavy))
                    .tracking(1)
                    .foregroundStyle(Theme.blue)
                Spacer()
                if !liveSteps.isEmpty, !isLiveRunning {
                    Button {
                        Haptics.light()
                        withAnimation(.snappy(duration: 0.2)) { liveSteps = [] }
                    } label: {
                        Text("CLEAR")
                            .font(Theme.mono(9, .heavy))
                            .tracking(0.8)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }

            ForEach(liveSteps) { step in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: step.isOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(step.isOK ? Theme.emerald : Theme.rose)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(step.title)
                            .font(Theme.mono(10.5, .heavy))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !step.detail.isEmpty {
                            Text(step.detail)
                                .font(Theme.mono(9.5))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                }
            }

            if let credential = liveCredential {
                credentialBlock(credential)
            }
        }
        .padding(12)
        .background(Theme.blueDim, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.blue.opacity(0.28)))
    }

    private func credentialBlock(_ credential: GeneratedCredential) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("STORED CREDENTIAL")
                .font(Theme.mono(8.5, .heavy))
                .tracking(1)
                .foregroundStyle(Theme.emerald)

            credRow(label: "EMAIL", value: credential.email)
            if !credential.username.isEmpty {
                credRow(label: "USERNAME", value: credential.username)
            }

            HStack(spacing: 8) {
                Text("PASSWORD")
                    .font(Theme.mono(9, .heavy))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textTertiary)
                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.emerald)
                Text("in Keychain (cred-\(credential.domain))")
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Button {
                    UIPasteboard.general.string = LiveRunService.password(forDomain: credential.domain)
                    Haptics.light()
                } label: {
                    Label("COPY", systemImage: "doc.on.doc")
                        .font(Theme.mono(9, .heavy))
                        .tracking(0.8)
                        .foregroundStyle(Theme.sky)
                }
            }
        }
        .padding(10)
        .background(Color(hex: 0x0C0C10), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.emerald.opacity(0.3)))
    }

    private func credRow(label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(Theme.mono(9, .heavy))
                .tracking(0.8)
                .foregroundStyle(Theme.textTertiary)
            Text(value)
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Button {
                UIPasteboard.general.string = value
                Haptics.light()
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.sky)
            }
        }
    }

    /// The full live credentials chain: discover → mint alias for email
    /// fields → generate password → fill → submit → poll the real inbox.
    private func runLive() async {
        guard !urlString.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isLiveRunning = true
        liveSteps = []
        liveCredential = nil
        lastResult = nil
        fetchedCode = nil
        codeStatusLine = nil
        Haptics.medium()

        let outcome = await LiveRunService.shared.run(
            url: urlString,
            method: method,
            person: nil,
            wants2FA: true,
            onStep: { step in
                withAnimation(.snappy(duration: 0.2)) { liveSteps.append(step) }
            },
            onFields: { updated in
                withAnimation(.snappy(duration: 0.2)) { fields = updated }
            }
        )

        if let result = outcome.result {
            withAnimation(.snappy(duration: 0.25)) { lastResult = result }
        }
        if let code = outcome.code {
            withAnimation(.snappy(duration: 0.25)) { fetchedCode = code }
        }
        withAnimation(.snappy(duration: 0.25)) { liveCredential = outcome.credential }
        isLiveRunning = false
        Haptics.medium()
    }

    private func addManualField() {
        let name = newFieldName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, fields.count < 30, !fields.contains(where: { $0.name == name }) else { return }
        Haptics.light()
        withAnimation(.snappy(duration: 0.2)) {
            fields.append(FormField(name: name, type: "text"))
        }
        newFieldName = ""
    }

    private func loadPreset(_ spec: FormSpec) {
        Haptics.light()
        urlString = spec.url
        method = spec.method
        fields = spec.fields
        lastResult = nil
        statusLine = nil
    }

    private func commitSavePreset() {
        let name = presetName.trimmingCharacters(in: .whitespaces)
        let fallback = URL(string: FormAutomationService.normalizedURL(urlString)?.absoluteString ?? "")?.host ?? "form"
        let spec = FormSpec(name: name.isEmpty ? fallback : name, url: urlString, method: method, fields: fields)
        service.savePreset(spec)
        presets = service.loadPresets()
        presetName = ""
        Haptics.light()
    }
}
