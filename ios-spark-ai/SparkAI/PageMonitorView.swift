//
//  PageMonitorView.swift
//  SparkAI
//
//  Monitor tab: register pages for AI scanning and change tracking. Each
//  card shows live hash-change status, HTTP outcome and the latest AI scan
//  report. Monitoring runs while the app is open; AI calls are gated by the
//  per-surface pageScan cloud consent.
//

import SwiftUI

struct PageMonitorView: View {
    @State private var viewModel = PageMonitorViewModel.shared
    @State private var urlString = ""
    @State private var intervalMinutes = 15
    @State private var consentAccepted = CloudConsent.isAccepted(.pageScan)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if !consentAccepted {
                        consentCard
                    }
                    addCard
                    if let lastError = viewModel.lastError {
                        errorLine(lastError)
                    }
                    if viewModel.pages.isEmpty {
                        emptyCard
                    }
                    ForEach(viewModel.pages) { page in
                        pageCard(page)
                    }
                }
                .padding(14)
                .padding(.bottom, 28)
            }
            .background(Theme.bgPrimary.ignoresSafeArea())
            .navigationTitle("Page Monitor")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Consent

    private var consentCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 15))
                .foregroundStyle(Theme.amber)

            VStack(alignment: .leading, spacing: 6) {
                Text("CLOUD AI DISCLOSURE")
                    .font(Theme.mono(10.5, .heavy))
                    .tracking(1)
                    .foregroundStyle(Theme.amber)
                Text("AI scans send a page's visible text to the Rork AI cloud provider for analysis. Change-detection hashes stay on-device. Accept to enable AI reports.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Haptics.light()
                    CloudConsent.accept(.pageScan)
                    consentAccepted = true
                } label: {
                    Text("I UNDERSTAND — ENABLE AI SCANS")
                        .font(Theme.mono(10, .heavy))
                        .tracking(0.8)
                        .foregroundStyle(Color(hex: 0x0C0C10))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.amber, in: .capsule)
                }
            }
        }
        .padding(14)
        .background(Theme.amber.opacity(0.07), in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.amber.opacity(0.28)))
    }

    // MARK: - Add

    private var addCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("ADD PAGE · RE-CHECK EVERY")
                    .font(Theme.mono(9, .heavy))
                    .tracking(1)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                ForEach(PageMonitorViewModel.intervalChoices, id: \.self) { minutes in
                    let selected = intervalMinutes == minutes
                    Button {
                        Haptics.light()
                        intervalMinutes = minutes
                    } label: {
                        Text("\(minutes)M")
                            .font(Theme.mono(9, .heavy))
                            .tracking(0.5)
                            .foregroundStyle(selected ? Theme.sky : Theme.textTertiary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(selected ? Theme.skyDim : Theme.bgSurface, in: .capsule)
                            .overlay(Capsule().strokeBorder(selected ? Theme.sky.opacity(0.5) : Theme.border))
                    }
                }
            }

            TextField("https://example.com/status", text: $urlString)
                .font(Theme.mono(12.5))
                .foregroundStyle(Theme.textPrimary)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.bgElevated, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
                .onSubmit { add() }

            Button {
                add()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 11, weight: .bold))
                    Text("START MONITORING")
                        .font(Theme.mono(10.5, .heavy))
                        .tracking(1)
                }
                .foregroundStyle(canAdd ? Theme.sky : Theme.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Theme.skyDim, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.sky.opacity(canAdd ? 0.3 : 0)))
            }
            .disabled(!canAdd)
        }
        .padding(12)
        .background(Theme.bgSurface.opacity(0.92), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
    }

    private var canAdd: Bool {
        !urlString.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func add() {
        Haptics.light()
        viewModel.addPage(urlString: urlString, intervalMinutes: intervalMinutes)
        urlString = ""
    }

    // MARK: - Empty + Error

    private var emptyCard: some View {
        Text("No pages yet. Add a URL above — Spark fetches it, hashes the visible text and asks the cloud AI for a structured scan report.")
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.bgSurface.opacity(0.92), in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
    }

    private func errorLine(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.rose)
            Text(message)
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.rose)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Page card

    private func pageCard(_ page: MonitoredPage) -> some View {
        let isScanning = viewModel.scanningIDs.contains(page.id)
        let hasScanned = page.lastCheckedAt != nil
        let outcomeColor: Color = {
            switch page.lastOutcome {
            case "changed": Theme.amber
            case "error": Theme.rose
            case "ok": Theme.emerald
            default: Theme.textTertiary
            }
        }()

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(hasScanned ? outcomeColor : Theme.textTertiary)
                    .frame(width: 7, height: 7)

                Text(page.label)
                    .font(Theme.mono(12, .heavy))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                Menu {
                    ForEach(PageMonitorViewModel.intervalChoices, id: \.self) { minutes in
                        Button("Every \(minutes) min") {
                            Haptics.light()
                            viewModel.setInterval(page.id, minutes)
                        }
                    }
                } label: {
                    Text("\(page.intervalMinutes)M")
                        .font(Theme.mono(8.5, .heavy))
                        .tracking(0.6)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Theme.bgActive, in: .capsule)
                }

                Button {
                    Haptics.light()
                    viewModel.scanNow(page.id)
                } label: {
                    if isScanning {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Theme.sky)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.sky)
                    }
                }
                .disabled(isScanning)

                Button {
                    Haptics.medium()
                    viewModel.remove(page.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            Text(page.url)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 6) {
                Text(outcomeLabel(page))
                    .font(Theme.mono(8.5, .heavy))
                    .tracking(0.6)
                    .foregroundStyle(hasScanned ? outcomeColor : Theme.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background((hasScanned ? outcomeColor : Theme.textTertiary).opacity(0.12), in: .capsule)

                if let checkedAt = page.lastCheckedAt {
                    Text(checkedAt.formatted(.relative(presentation: .named)))
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.textTertiary)
                }

                Spacer()

                Button {
                    Haptics.light()
                    viewModel.setEnabled(page.id, !page.isEnabled)
                } label: {
                    Image(systemName: page.isEnabled ? "pause.fill" : "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(page.isEnabled ? Theme.textSecondary : Theme.amber)
                }
            }

            let meta = pageMeta(page)
            if !meta.isEmpty {
                Text(meta)
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
            }

            if !page.aiSummary.isEmpty {
                Text(page.aiSummary)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(12)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: 0x0C0C10), in: .rect(cornerRadius: 10))
            }
        }
        .padding(12)
        .background(Theme.bgSurface.opacity(0.92), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(hasScanned ? outcomeColor.opacity(0.25) : Theme.border))
    }

    private func outcomeLabel(_ page: MonitoredPage) -> String {
        switch page.lastOutcome {
        case "changed": "CHANGED"
        case "error": "ERROR"
        case "ok": "OK"
        default: "PENDING"
        }
    }

    private func pageMeta(_ page: MonitoredPage) -> String {
        var parts: [String] = []
        if page.lastHTTPStatus > 0 { parts.append("HTTP \(page.lastHTTPStatus)") }
        if page.changeCount > 0 {
            parts.append("\(page.changeCount) change\(page.changeCount == 1 ? "" : "s")")
        }
        if let changedAt = page.lastChangedAt {
            parts.append("changed \(changedAt.formatted(.relative(presentation: .named)))")
        }
        if !page.isEnabled { parts.append("PAUSED") }
        return parts.joined(separator: " · ")
    }
}

#Preview {
    PageMonitorView()
}
