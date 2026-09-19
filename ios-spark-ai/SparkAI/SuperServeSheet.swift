//
//  SuperServeSheet.swift
//  SparkAI
//
//  Provisioning sheet for the SuperServe cloud sandbox: API key (Keychain),
//  live status, wake/sleep, a team sandbox picker, a "Test now" probe, exec
//  settings, published preview ports (opened in an in-app browser) and the
//  lifecycle log.
//

import SwiftUI
import Combine
import SafariServices

struct SuperServeSheet: View {
    let viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var host = SuperServeService.shared
    @State private var config = SuperServeConfig()
    @State private var sandbox = SandboxConfig()
    @State private var apiKeyDraft = ""
    @State private var timeoutText = ""
    @State private var portDraft = ""
    @State private var envNameDraft = ""
    @State private var uptimeTick = Date()
    @State private var previewURL: URL?

    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard.entrance()
                    if host.hasAPIKey {
                        primaryAction.entrance(delay: 0.04)
                    }
                    keyCard.entrance(delay: 0.08)
                    if host.hasAPIKey {
                        environmentsCard.entrance(delay: 0.12)
                        sandboxCard.entrance(delay: 0.16)
                        execCard.entrance(delay: 0.2)
                        previewCard.entrance(delay: 0.24)
                    }
                    if !host.events.isEmpty {
                        eventLog.entrance(delay: 0.28)
                    }
                }
                .padding(16)
            }
            .background(Theme.bgPrimary)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Image(systemName: "cloud.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.sandbox)
                        Text("SUPERSERVE")
                            .font(Theme.display(14, .bold))
                            .tracking(2)
                            .foregroundStyle(Theme.textPrimary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        IconChip(systemName: "xmark", tint: Theme.textSecondary, size: 30, cornerRadius: 9)
                    }
                    .buttonStyle(.pressable)
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(item: $previewURL) { url in
            SafariView(url: url).ignoresSafeArea()
        }
        .onAppear {
            config = host.config
            sandbox = viewModel.sandboxConfig
            timeoutText = String(config.timeoutSeconds)
            Task {
                await host.refreshStatus()
                if host.hasAPIKey { await host.listSandboxes() }
            }
        }
        .onReceive(clock) { _ in uptimeTick = Date() }
    }

    // MARK: - Status

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(stateColor.opacity(0.16))
                        .frame(width: 46, height: 46)
                    if host.isReady {
                        Circle()
                            .stroke(stateColor.opacity(0.4), lineWidth: 1)
                            .frame(width: 46, height: 46)
                            .scaleEffect(uptimeTick.timeIntervalSince1970.truncatingRemainder(dividingBy: 2) < 1 ? 1.14 : 1)
                            .opacity(uptimeTick.timeIntervalSince1970.truncatingRemainder(dividingBy: 2) < 1 ? 0 : 1)
                            .animation(.easeOut(duration: 1), value: uptimeTick)
                    }
                    Image(systemName: statusIcon)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(stateColor)
                        .symbolEffect(.pulse, isActive: host.isBusy)
                        .contentTransition(.symbolEffect(.replace))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(host.state.label)
                        .font(Theme.display(17, .bold))
                        .tracking(1.4)
                        .foregroundStyle(Theme.textPrimary)
                        .contentTransition(.opacity)
                    Text(subtitle)
                        .font(Theme.mono(10, .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    Task {
                        await host.refreshStatus()
                        await host.listSandboxes()
                    }
                } label: {
                    IconChip(systemName: "arrow.clockwise", tint: Theme.sandbox, size: 32, cornerRadius: 9)
                }
                .buttonStyle(.pressable)
                .disabled(host.isBusy)
            }

            HStack(spacing: 0) {
                statLabel("UPTIME", host.isReady ? host.uptimeText : "—")
                divider
                statLabel("RUNS IN", "CLOUD")
                divider
                statLabel("SANDBOX", host.activeEnvironment?.name.uppercased() ?? String(config.sandboxID.prefix(8)))
            }

            Text("Commands run on SuperServe's cloud infrastructure, not on your network.")
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bgSurface, in: .rect(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(stateColor.opacity(host.isReady ? 0.35 : 0.14))
        )
        .shadow(color: host.isReady ? Theme.sandbox.opacity(0.18) : .clear, radius: 18, y: 6)
        .animation(Theme.snap, value: host.state)
    }

    private var statusIcon: String {
        switch host.state {
        case .unauthenticated: "key.slash"
        case .asleep: "moon.zzz.fill"
        case .waking: "hourglass"
        case .ready: "cloud.fill"
        case .missing: "questionmark.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var subtitle: String {
        if let env = host.activeEnvironment {
            let template = host.info?.template.map { " · \($0)" } ?? ""
            return "\(env.name)\(template)"
        }
        if let info = host.info {
            let template = info.template.map { " · \($0)" } ?? ""
            return "\(info.displayName)\(template)"
        }
        return host.hasAPIKey ? config.sandboxID : "Add your API key to begin"
    }

    private var divider: some View {
        Rectangle().fill(Theme.border).frame(width: 1, height: 26)
    }

    private func statLabel(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(Theme.mono(8.5, .heavy))
                .tracking(1)
                .foregroundStyle(Theme.textTertiary)
            Text(value)
                .font(Theme.mono(11, .semibold))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    private var stateColor: Color {
        switch host.state {
        case .ready: Theme.sandbox
        case .waking: Theme.amber
        case .failed, .missing: Theme.rose
        case .asleep, .unauthenticated: Theme.textTertiary
        }
    }

    // MARK: - Primary action

    private var primaryAction: some View {
        VStack(spacing: 10) {
            if host.state == .missing {
                Button {
                    Task {
                        let created = await host.createSandbox()
                        if created {
                            config = host.config
                            pointTerminalAtSandbox()
                        }
                    }
                } label: {
                    actionLabel(icon: "plus.circle.fill", title: "CREATE A NEW SANDBOX", isDestructive: false)
                }
                .buttonStyle(.pressable(scale: 0.97))
                .disabled(host.isBusy)
            } else {
                Button {
                    Task {
                        if host.isReady {
                            await host.sleep()
                        } else {
                            let woke = await host.wake()
                            if woke { pointTerminalAtSandbox() }
                        }
                    }
                } label: {
                    actionLabel(
                        icon: host.isReady ? "moon.fill" : "bolt.fill",
                        title: host.isBusy ? host.state.label : (host.isReady ? "PUT TO SLEEP" : "WAKE SANDBOX"),
                        isDestructive: host.isReady
                    )
                }
                .buttonStyle(.pressable(scale: 0.97))
                .disabled(host.isBusy || !config.isValid)
                .animation(Theme.snap, value: host.isReady)
            }

            // Test now — proves the key + sandbox work end to end.
            Button {
                Task { await host.testConnection() }
            } label: {
                HStack(spacing: 8) {
                    if host.isTesting {
                        ProgressView().scaleEffect(0.7).tint(Theme.sandbox)
                    } else {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 12, weight: .bold))
                    }
                    Text(host.isTesting ? "TESTING…" : "TEST NOW")
                        .font(Theme.mono(10.5, .bold))
                        .tracking(1.2)
                }
                .foregroundStyle(Theme.sandbox)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Theme.sandboxDim, in: .rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.sandbox.opacity(0.35)))
            }
            .buttonStyle(.pressable(scale: 0.98))
            .disabled(host.isTesting || host.isBusy)

            if let test = host.lastTest {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: test.isOk ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(test.isOk ? Theme.emerald : Theme.rose)
                        .padding(.top, 1)
                    Text(test.output.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(Theme.mono(10))
                        .foregroundStyle(test.isOk ? Theme.textSecondary : Theme.rose)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(11)
                .background(Theme.bgElevated, in: .rect(cornerRadius: 11))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if host.isReady {
                Button {
                    pointTerminalAtSandbox()
                    dismiss()
                } label: {
                    Text(sandbox.target == .superserve ? "TERMINAL IS ON SANDBOX" : "POINT TERMINAL AT SANDBOX")
                        .font(Theme.mono(10.5, .bold))
                        .tracking(1.2)
                        .foregroundStyle(sandbox.target == .superserve ? Theme.sandbox : Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Theme.bgElevated, in: .rect(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(sandbox.target == .superserve ? Theme.sandbox.opacity(0.4) : Theme.border)
                        )
                }
                .buttonStyle(.pressable(scale: 0.98))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Theme.reveal, value: host.isReady)
        .animation(Theme.reveal, value: host.lastTest)
    }

    private func actionLabel(icon: String, title: String, isDestructive: Bool) -> some View {
        HStack(spacing: 10) {
            if host.isBusy {
                ProgressView().tint(isDestructive ? Theme.rose : Theme.bgPrimary)
            } else {
                Image(systemName: icon).font(.system(size: 14, weight: .bold))
            }
            Text(title)
                .font(Theme.display(15, .bold))
                .tracking(1.6)
        }
        .foregroundStyle(isDestructive ? Theme.rose : Theme.bgPrimary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 15)
        .background {
            if isDestructive {
                Theme.rose.opacity(0.14)
            } else {
                LinearGradient(
                    colors: [Theme.sandbox, Theme.blue],
                    startPoint: .leading, endPoint: .trailing
                )
            }
        }
        .clipShape(.rect(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(isDestructive ? Theme.rose.opacity(0.4) : .clear)
        )
        .shadow(color: isDestructive ? .clear : Theme.sandbox.opacity(0.4), radius: 16, y: 6)
    }

    // MARK: - API key

    private var keyCard: some View {
        card("API KEY", icon: "key.fill") {
            if host.hasAPIKey {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.emerald)
                    Text("Stored in the Keychain")
                        .font(Theme.mono(11, .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button {
                        Haptics.medium()
                        host.clearAPIKey()
                        apiKeyDraft = ""
                    } label: {
                        Text("REPLACE")
                            .font(Theme.mono(9.5, .bold))
                            .tracking(0.8)
                            .foregroundStyle(Theme.rose)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Theme.rose.opacity(0.12), in: .capsule)
                    }
                    .buttonStyle(.pressable)
                }
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    SecureField("ss_live_…", text: $apiKeyDraft)
                        .font(Theme.mono(12.5))
                        .foregroundStyle(Theme.textPrimary)
                        .tint(Theme.sandbox)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(9)
                        .background(Theme.bgElevated, in: .rect(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))

                    Button {
                        host.setAPIKey(apiKeyDraft)
                        apiKeyDraft = ""
                        Haptics.success()
                        Task {
                            await host.listSandboxes()
                            await host.refreshStatus()
                        }
                    } label: {
                        Text("SAVE KEY")
                            .font(Theme.mono(10.5, .bold))
                            .tracking(1.2)
                            .foregroundStyle(Theme.bgPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(Theme.sandbox, in: .rect(cornerRadius: 11))
                    }
                    .buttonStyle(.pressable(scale: 0.98))
                    .disabled(apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)

                    Text("Create a key in the SuperServe Console. It is written straight to the device Keychain and never shown again.")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    // MARK: - Saved environments

    private var environmentsCard: some View {
        card("ENVIRONMENTS", icon: "square.stack.3d.up.fill") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(config.environments) { env in
                        let isActive = env.sandboxID == config.sandboxID
                        Button {
                            host.select(env)
                            config = host.config
                            Haptics.selection()
                            Task { await host.refreshStatus() }
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(isActive ? Theme.bgPrimary : Theme.sandbox)
                                    .frame(width: 5, height: 5)
                                Text(env.name.uppercased())
                                    .font(Theme.mono(10, .heavy))
                                    .tracking(1)
                            }
                            .foregroundStyle(isActive ? Theme.bgPrimary : Theme.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(isActive ? Theme.sandbox : Theme.bgElevated, in: .capsule)
                            .overlay(Capsule().strokeBorder(isActive ? Theme.sandbox : Theme.border))
                        }
                        .buttonStyle(.pressable)
                        .contextMenu {
                            Button(role: .destructive) {
                                host.removeEnvironment(env)
                                config = host.config
                                Haptics.medium()
                            } label: {
                                Label("Remove \(env.name)", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .animation(Theme.snap, value: config.sandboxID)

            HStack(spacing: 8) {
                TextField("name this sandbox…", text: $envNameDraft)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.textPrimary)
                    .tint(Theme.sandbox)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(9)
                    .background(Theme.bgElevated, in: .rect(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))

                Button {
                    host.saveEnvironment(name: envNameDraft, sandboxID: config.sandboxID)
                    config = host.config
                    envNameDraft = ""
                    Haptics.success()
                } label: {
                    Text("SAVE")
                        .font(Theme.mono(10, .bold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.bgPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(Theme.sandbox, in: .rect(cornerRadius: 10))
                }
                .buttonStyle(.pressable(scale: 0.96))
                .disabled(envNameDraft.trimmingCharacters(in: .whitespaces).isEmpty || !config.isValid)
            }

            Text("Saves the current sandbox id under a name. Long-press a chip to remove it.")
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: - Sandbox picker

    private var sandboxCard: some View {
        card("SANDBOX", icon: "shippingbox.fill") {
            field("SANDBOX ID", text: $config.sandboxID, placeholder: "75be2c5c-…")
                .onChange(of: config.sandboxID) { _, _ in host.update(config) }

            if host.sandboxes.isEmpty {
                HStack(spacing: 7) {
                    if host.isListing {
                        ProgressView().scaleEffect(0.6).tint(Theme.sandbox)
                    }
                    Text(host.isListing ? "Loading sandboxes…" : "No sandboxes found on this team yet.")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.textTertiary)
                }
            } else {
                VStack(spacing: 6) {
                    ForEach(host.sandboxes) { item in
                        Button {
                            var next = config
                            next.sandboxID = item.id
                            next.publishedPorts = []
                            config = next
                            host.update(next)
                            Haptics.selection()
                            Task { await host.refreshStatus() }
                        } label: {
                            HStack(spacing: 9) {
                                Circle()
                                    .fill(item.isActive ? Theme.emerald : Theme.textTertiary)
                                    .frame(width: 6, height: 6)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.displayName)
                                        .font(Theme.mono(11.5, .semibold))
                                        .foregroundStyle(Theme.textPrimary)
                                    Text(item.id)
                                        .font(Theme.mono(8.5))
                                        .foregroundStyle(Theme.textTertiary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if item.id == config.sandboxID {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(Theme.sandbox)
                                }
                            }
                            .padding(10)
                            .background(
                                item.id == config.sandboxID ? Theme.sandboxDim : Theme.bgElevated,
                                in: .rect(cornerRadius: 11)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 11)
                                    .strokeBorder(item.id == config.sandboxID ? Theme.sandbox.opacity(0.4) : Theme.border)
                            )
                        }
                        .buttonStyle(.pressable(scale: 0.98))
                    }
                }
                .animation(Theme.snap, value: config.sandboxID)
            }

            Button {
                Task {
                    let created = await host.createSandbox()
                    if created { config = host.config }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                    Text("NEW SANDBOX · PREVIEW \(config.previewAccess.uppercased())")
                        .font(Theme.mono(9.5, .bold))
                        .tracking(0.8)
                }
                .foregroundStyle(Theme.sandbox)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(Theme.sandboxDim, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.sandbox.opacity(0.3)))
            }
            .buttonStyle(.pressable(scale: 0.98))
            .disabled(host.isBusy)
        }
    }

    // MARK: - Exec settings

    private var execCard: some View {
        card("EXECUTION", icon: "terminal.fill") {
            field("WORKING DIR", text: $config.workingDir, placeholder: "/home/user")
                .onChange(of: config.workingDir) { _, _ in host.update(config) }
            field("TIMEOUT (S)", text: $timeoutText, placeholder: "120", numeric: true)
                .onChange(of: timeoutText) { _, _ in
                    var next = config
                    next.timeoutSeconds = Int(timeoutText) ?? next.timeoutSeconds
                    config = next
                    host.update(next)
                }
        }
    }

    // MARK: - Preview ports

    private var previewCard: some View {
        card("PREVIEW PORTS", icon: "globe") {
            HStack(spacing: 8) {
                TextField("8080", text: $portDraft)
                    .font(Theme.mono(12.5))
                    .foregroundStyle(Theme.textPrimary)
                    .tint(Theme.sandbox)
                    .keyboardType(.numberPad)
                    .padding(9)
                    .background(Theme.bgElevated, in: .rect(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))

                Button {
                    if let port = Int(portDraft) {
                        host.publishPort(port)
                        config = host.config
                        portDraft = ""
                        Haptics.success()
                    }
                } label: {
                    Text("PUBLISH")
                        .font(Theme.mono(10, .bold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.bgPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(Theme.sandbox, in: .rect(cornerRadius: 10))
                }
                .buttonStyle(.pressable(scale: 0.96))
                .disabled(Int(portDraft) == nil)
            }

            if config.publishedPorts.isEmpty {
                Text("Serve on 0.0.0.0 inside the sandbox, then publish the port to get a public link.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                VStack(spacing: 6) {
                    ForEach(config.publishedPorts, id: \.self) { port in
                        HStack(spacing: 9) {
                            Button {
                                previewURL = host.previewURL(port: port)
                                Haptics.light()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "safari.fill")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(Theme.sandbox)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("PORT \(port)")
                                            .font(Theme.mono(10.5, .bold))
                                            .tracking(0.8)
                                            .foregroundStyle(Theme.textPrimary)
                                        Text(host.previewURL(port: port)?.absoluteString ?? "")
                                            .font(Theme.mono(8.5))
                                            .foregroundStyle(Theme.textTertiary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.pressable(scale: 0.98))

                            Button {
                                UIPasteboard.general.string = host.previewURL(port: port)?.absoluteString
                                Haptics.success()
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.textTertiary)
                                    .frame(width: 26, height: 26)
                            }
                            .buttonStyle(.pressable(haptic: false))

                            Button {
                                host.retirePort(port)
                                config = host.config
                                Haptics.medium()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Theme.rose)
                                    .frame(width: 26, height: 26)
                            }
                            .buttonStyle(.pressable(haptic: false))
                        }
                        .padding(9)
                        .background(Theme.bgElevated, in: .rect(cornerRadius: 11))
                        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.border))
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                }
                .animation(Theme.snap, value: config.publishedPorts)
            }
        }
    }

    // MARK: - Event log

    private var eventLog: some View {
        card("LIFECYCLE", icon: "list.bullet.rectangle") {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(host.events) { event in
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: event.isOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(event.isOK ? Theme.sandbox : Theme.rose)
                            .padding(.top, 1.5)
                        Text(event.text)
                            .font(Theme.mono(10.5))
                            .foregroundStyle(event.isOK ? Theme.textSecondary : Theme.rose)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .animation(Theme.reveal, value: host.events.count)
        }
    }

    // MARK: - Building blocks

    private func card<Content: View>(
        _ title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.sandbox)
                Text(title)
                    .font(Theme.mono(9.5, .heavy))
                    .tracking(1.3)
                    .foregroundStyle(Theme.textTertiary)
            }
            content()
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bgSurface, in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.border))
    }

    private func field(
        _ label: String,
        text: Binding<String>,
        placeholder: String,
        numeric: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Theme.mono(8.5, .heavy))
                .tracking(0.9)
                .foregroundStyle(Theme.textTertiary)
            TextField(placeholder, text: text)
                .font(Theme.mono(12.5))
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.sandbox)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(numeric ? .numberPad : .asciiCapable)
                .padding(9)
                .background(Theme.bgElevated, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
        }
    }

    private func pointTerminalAtSandbox() {
        sandbox.target = .superserve
        viewModel.updateSandboxConfig(sandbox)
    }
}

// MARK: - In-app browser

/// SFSafariViewController wrapper for opening sandbox preview URLs in-app.
private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        let controller = SFSafariViewController(url: url, configuration: config)
        controller.preferredControlTintColor = UIColor(Theme.sandbox)
        controller.preferredBarTintColor = UIColor(Theme.bgPrimary)
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

#Preview {
    SuperServeSheet(viewModel: ChatViewModel())
        .preferredColorScheme(.dark)
}
