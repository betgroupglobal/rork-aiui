//
//  PeopleView.swift
//  SparkAI
//
//  People roster sheet: import a CSV of people details (template provided),
//  add people manually, and apply a person to the open form's fields with
//  one tap. Data stays on-device.
//

import SwiftUI
import UniformTypeIdentifiers

struct PeopleView: View {
    @Environment(\.dismiss) private var dismiss

    /// Called when the user taps USE on a person — the opener applies the
    /// person's details to the current form fields.
    var onApply: ((Person) -> Void)?

    @State private var people: [Person] = []
    @State private var showImporter = false
    @State private var statusLine: String?
    @State private var newFirstName = ""
    @State private var newLastName = ""
    @State private var newEmail = ""

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 14) {
                    templateCard
                    importCard
                    addCard
                    rosterSection
                }
                .padding(14)
                .padding(.bottom, 28)
            }
        }
        .background(Theme.bgPrimary.ignoresSafeArea())
        .onAppear { people = PeopleStore.shared.people }
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
                Text("PEOPLE ROSTER")
                    .font(Theme.mono(13, .heavy))
                    .tracking(1.5)
                    .foregroundStyle(Theme.textPrimary)
                Text("CSV IMPORT · FORM FILL · ON-DEVICE")
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

    // MARK: - Template

    private var templateCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TEMPLATE CSV")
                .font(Theme.mono(9, .heavy))
                .tracking(1)
                .foregroundStyle(Theme.textTertiary)

            Text(PeopleStore.templateCSV)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(hex: 0x0C0C10), in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))

            HStack(spacing: 8) {
                Button {
                    UIPasteboard.general.string = PeopleStore.templateCSV
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

                ShareLink(item: PeopleStore.templateCSV, preview: SharePreview("spark-people-template.csv")) {
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
        VStack(alignment: .leading, spacing: 8) {
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
                    Text("IMPORT CSV FILE")
                        .font(Theme.mono(10.5, .heavy))
                        .tracking(1)
                }
                .foregroundStyle(Theme.sky)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Theme.skyDim, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.sky.opacity(0.3)))
            }

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

    // MARK: - Manual add

    private var canAdd: Bool {
        !newFirstName.trimmingCharacters(in: .whitespaces).isEmpty
            || !newEmail.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var addCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ADD MANUALLY")
                .font(Theme.mono(9, .heavy))
                .tracking(1)
                .foregroundStyle(Theme.textTertiary)

            HStack(spacing: 8) {
                TextField("First name", text: $newFirstName)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Theme.bgElevated, in: .rect(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                TextField("Last name", text: $newLastName)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Theme.bgElevated, in: .rect(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            }

            HStack(spacing: 8) {
                TextField("email@example.com", text: $newEmail)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.textPrimary)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Theme.bgElevated, in: .rect(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))

                Button {
                    commitAdd()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.sky)
                        .frame(width: 38, height: 38)
                        .background(Theme.skyDim, in: .rect(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.sky.opacity(0.3)))
                }
                .disabled(!canAdd)
                .opacity(canAdd ? 1 : 0.4)
            }
        }
        .padding(12)
        .background(Theme.bgSurface.opacity(0.92), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
    }

    // MARK: - Roster

    private var rosterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ROSTER (\(people.count))")
                .font(Theme.mono(9, .heavy))
                .tracking(1)
                .foregroundStyle(Theme.textTertiary)

            if people.isEmpty {
                Text("No people yet — import a CSV or add someone manually. Their details fill matching form fields automatically (name, email, phone, company…).")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }

            ForEach(people) { person in
                personRow(person)
            }
        }
        .padding(12)
        .background(Theme.bgSurface.opacity(0.92), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
    }

    private func personRow(_ person: Person) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(person.displayName)
                    .font(Theme.mono(11.5, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if let onApply {
                    Button {
                        Haptics.light()
                        onApply(person)
                        dismiss()
                    } label: {
                        Text("USE")
                            .font(Theme.mono(9, .heavy))
                            .tracking(0.8)
                            .foregroundStyle(Theme.emerald)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Theme.emeraldDim, in: .capsule)
                            .overlay(Capsule().strokeBorder(Theme.emerald.opacity(0.3)))
                    }
                }

                Button {
                    Haptics.medium()
                    PeopleStore.shared.remove(person.id)
                    people = PeopleStore.shared.people
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            let details = [person.email, person.phone, person.company]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            if !details.isEmpty {
                Text(details)
                    .font(Theme.mono(10))
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

    private func commitAdd() {
        guard canAdd else { return }
        Haptics.light()
        PeopleStore.shared.add(
            Person(
                firstName: newFirstName.trimmingCharacters(in: .whitespaces),
                lastName: newLastName.trimmingCharacters(in: .whitespaces),
                email: newEmail.trimmingCharacters(in: .whitespaces)
            )
        )
        people = PeopleStore.shared.people
        newFirstName = ""
        newLastName = ""
        newEmail = ""
        statusLine = nil
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            statusLine = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                statusLine = "Couldn't read the file as UTF-8 text"
                return
            }
            Haptics.light()
            let added = PeopleStore.shared.importCSV(text)
            people = PeopleStore.shared.people
            statusLine = added > 0
                ? "Imported \(added) people"
                : "Nothing imported — match the template columns"
        }
    }
}
