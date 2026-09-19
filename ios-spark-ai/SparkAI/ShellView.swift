//
//  ShellView.swift
//  SparkAI
//
//  The Auto Bash Shell terminal drawer, ported from aiui. Executes real
//  commands on the sandbox runner (Local Mac or DGX Spark GB10) with live
//  health, exit codes and latency.
//

import SwiftUI

struct ShellView: View {
    let viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var config = SandboxConfig()
    @State private var portText = ""
    @State private var command = ""
    @State private var history: [ShellRunResult] = []
    @State private var isRunning = false
    @State private var health = SandboxService.Status(isOnline: false, latencyMs: nil, error: nil)
    @State private var showConfig = false
    @State private var showSandboxSheet = false
    @State private var cloud = SuperServeService.shared
    @State private var liveOutput = ""
    @State private var liveCommand = ""
    @FocusState private var isInputFocused: Bool

    /// Accent for the active target — the cloud sandbox has its own hue.
    private var accent: Color {
        tint(for: config.target)
    }

    private func tint(for target: SandboxTarget) -> Color {
        target == .superserve ? Theme.sandbox : Theme.emerald
    }

    /// Lifecycle label of the managed host backing the active target.
    private var managedStateLabel: String {
        config.target == .superserve ? cloud.state.label : ""
    }

    /// Whether the managed host backing the active target can take commands.
    private var isManagedReady: Bool {
        config.target == .superserve ? cloud.isReady : true
    }

    private var isManagedBusy: Bool {
        config.target == .superserve ? cloud.isBusy : false
    }

    /// Opens the provisioning sheet for the active managed target.
    private func openManagedSheet() {
        Haptics.light()
        showSandboxSheet = true
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            console
            diagnosticsRow
            inputBar
        }
        .background(Theme.bgPrimary)
        .onAppear {
            config = viewModel.sandboxConfig
            portText = String(config.port)
            Task { await refreshHealth() }
        }
        .sheet(isPresented: $showSandboxSheet) {
            SuperServeSheet(viewModel: viewModel)
                .onDisappear { syncAfterSheet() }
        }
        .onChange(of: config.host) { _, _ in save() }
        .onChange(of: config.target) { _, _ in save() }
        .onChange(of: config.workspaceDir) { _, _ in save() }
        .onChange(of: portText) { _, _ in save() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: headerIcon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(accent)
                    .frame(width: 32, height: 32)
                    .background(accent.opacity(0.14), in: .rect(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(accent.opacity(0.3)))
                    .contentTransition(.symbolEffect(.replace))

                VStack(alignment: .leading, spacing: 1) {
                    Text(headerTitle)
                        .font(Theme.display(15, .bold))
                        .tracking(1.5)
                        .foregroundStyle(Theme.textPrimary)
                        .contentTransition(.opacity)
                    Text(statusLine)
                        .font(Theme.mono(9.5, .semibold))
                        .foregroundStyle(health.isOnline ? accent : Theme.rose)
                        .tracking(1)
                }

                Spacer()

                // Health dot
                Button {
                    Task { await refreshHealth() }
                } label: {
                    Circle()
                        .fill(health.isOnline ? accent : Theme.rose)
                        .frame(width: 8, height: 8)
                        .shadow(color: (health.isOnline ? accent : Theme.rose).opacity(0.8), radius: 4)
                        .frame(width: 28, height: 32)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Refresh runner health")

                Button {
                    Haptics.light()
                    showSandboxSheet = true
                } label: {
                    IconChip(systemName: "cloud.fill", tint: Theme.sandbox, isActive: cloud.isReady, size: 32, cornerRadius: 9)
                        .overlay(alignment: .topTrailing) {
                            if cloud.isBusy {
                                Circle().fill(Theme.amber).frame(width: 6, height: 6).offset(x: 2, y: -2)
                            }
                        }
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("SuperServe sandbox")

                Button {
                    withAnimation(Theme.snap) { showConfig.toggle() }
                } label: {
                    IconChip(systemName: "slider.horizontal.3", tint: accent, isActive: showConfig, size: 32, cornerRadius: 9)
                }
                .buttonStyle(.pressable)
            }

            HStack(spacing: 8) {
                ForEach(SandboxTarget.allCases, id: \.self) { target in
                    Button {
                        withAnimation(Theme.snap) { config.target = target }
                    } label: {
                        HStack(spacing: 4) {
                            if isReady(target) {
                                Circle()
                                    .fill(config.target == target ? Theme.bgPrimary : tint(for: target))
                                    .frame(width: 5, height: 5)
                            }
                            Text(target.label)
                                .font(Theme.mono(10, .heavy))
                                .tracking(1)
                        }
                        .foregroundStyle(config.target == target ? Theme.bgPrimary : Theme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(config.target == target ? tint(for: target) : Theme.bgElevated, in: .capsule)
                        .overlay(Capsule().strokeBorder(config.target == target ? tint(for: target) : Theme.border))
                    }
                    .buttonStyle(.pressable)
                }

                Spacer()

                Toggle(isOn: $config.autoRun) { }
                    .labelsHidden()
                    .tint(accent)
                    .onChange(of: config.autoRun) { _, _ in
                        Haptics.light()
                        viewModel.updateSandboxConfig(config)
                    }
            }

            if config.autoRun {
                Text("AUTO-BASH ON — shell commands from assistant replies run automatically and appear in chat.")
                    .font(Theme.mono(9, .semibold))
                    .foregroundStyle(accent)
                    .tracking(0.4)
            }

            if config.target.isManagedHost, !isManagedReady {
                Button {
                    openManagedSheet()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "bolt.fill").font(.system(size: 10, weight: .bold))
                        Text(isManagedBusy
                             ? "SANDBOX \(managedStateLabel)…"
                             : (cloud.hasAPIKey ? "SANDBOX ASLEEP — WAKE IT" : "ADD YOUR SUPERSERVE API KEY"))
                            .font(Theme.mono(9.5, .bold))
                            .tracking(0.8)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(accent)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .background(accent.opacity(0.14), in: .rect(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(accent.opacity(0.32)))
                }
                .buttonStyle(.pressable(scale: 0.98))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if showConfig {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        configField("HOST", text: $config.host, placeholder: "127.0.0.1")
                        configField("PORT", text: $portText, placeholder: "17330")
                    }
                    configField("WORKSPACE", text: $config.workspaceDir, placeholder: "/tmp/spark-sandboxes")
                    Text("Start the runner on the host: `npm run sandbox` (aiui sandbox, port 17330).")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.top, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .background(.ultraThinMaterial.opacity(0.4))
        .animation(Theme.snap, value: config.target)
        .animation(Theme.snap, value: cloud.state)
    }

    private var headerIcon: String {
        config.target == .superserve ? "cloud.fill" : "terminal"
    }

    private var headerTitle: String {
        config.target == .superserve ? "CLOUD SANDBOX" : "AUTO BASH"
    }

    private func isReady(_ target: SandboxTarget) -> Bool {
        target == .superserve ? cloud.isReady : false
    }

    private func syncAfterSheet() {
        config = viewModel.sandboxConfig
        portText = String(config.port)
        Task { await refreshHealth() }
    }

    private var statusLine: String {
        guard health.isOnline, let latency = health.latencyMs else {
            return health.error?.uppercased() ?? "OFFLINE"
        }
        if config.target.isManagedHost {
            return "\(config.target.label) · \(managedStateLabel) · \(latency)MS"
        }
        return "\(config.target.label) · \(latency)MS"
    }

    private func configField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Theme.mono(9, .heavy))
                .tracking(0.8)
                .foregroundStyle(Theme.textTertiary)
            TextField(placeholder, text: text)
                .font(Theme.mono(12.5))
                .foregroundStyle(Theme.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(label == "PORT" ? .numberPad : .asciiCapable)
                .padding(9)
                .background(Theme.bgElevated, in: .rect(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
        }
    }

    // MARK: - Console

    private var console: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if history.isEmpty, !isRunning {
                        emptyConsole
                    } else {
                        ForEach(Array(history.enumerated()), id: \.offset) { index, result in
                            ShellEntry(result: result, accent: tint(for: result.target))
                                .id(index)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }

                    if isRunning {
                        LiveShellEntry(command: liveCommand, output: liveOutput, accent: accent)
                            .id("live")
                            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
                    }
                }
                .padding(14)
                .animation(Theme.reveal, value: history.count)
                .animation(Theme.snap, value: isRunning)
            }
            .onChange(of: history.count) { _, _ in
                withAnimation(Theme.reveal) {
                    proxy.scrollTo(history.count - 1, anchor: .bottom)
                }
            }
            .onChange(of: liveOutput) { _, _ in
                proxy.scrollTo("live", anchor: .bottom)
            }
        }
        .background(Theme.bgPrimary)
    }

    private var emptyConsole: some View {
        VStack(spacing: 10) {
            Image(systemName: emptyConsoleIcon)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(config.target.isManagedHost ? accent.opacity(0.7) : Theme.textTertiary)
            Text(emptyConsoleMessage)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)

            if config.target.isManagedHost, !isManagedReady {
                Button {
                    openManagedSheet()
                } label: {
                    Text(cloud.hasAPIKey ? "OPEN SANDBOX" : "ADD API KEY")
                        .font(Theme.mono(10, .bold))
                        .tracking(1.2)
                        .foregroundStyle(accent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(accent.opacity(0.14), in: .capsule)
                        .overlay(Capsule().strokeBorder(accent.opacity(0.35)))
                }
                .buttonStyle(.pressable)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 72)
    }

    private var emptyConsoleIcon: String {
        guard config.target == .superserve else { return "chevron.left.forwardslash.chevron.right" }
        if !cloud.hasAPIKey { return "key.slash" }
        switch cloud.state {
        case .ready: return "cloud.fill"
        case .missing: return "questionmark.circle"
        default: return "moon.zzz.fill"
        }
    }

    private var emptyConsoleMessage: String {
        guard config.target == .superserve else {
            return health.isOnline
                ? "Runner online — execute a command or tap a diagnostic."
                : "Runner offline — start `npm run sandbox` on the host, then tap the health dot."
        }
        if !cloud.hasAPIKey {
            return "No SuperServe API key yet — add one to run commands in the cloud sandbox."
        }
        switch cloud.state {
        case .ready:
            return "Sandbox ready — commands run in the cloud, reachable from anywhere."
        case .missing:
            return "That sandbox no longer exists — pick another one or create a fresh sandbox."
        default:
            return "Sandbox asleep — wake it, or just run a command and it will wake first."
        }
    }

    // MARK: - Diagnostics + input

    private var diagnosticsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(diagnostics, id: \.self) { diag in
                    Button {
                        run(diag)
                    } label: {
                        Text(diag)
                            .font(Theme.mono(11, .semibold))
                            .foregroundStyle(diagnosticTint)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(diagnosticTint.opacity(0.13), in: .capsule)
                            .overlay(Capsule().strokeBorder(diagnosticTint.opacity(0.25)))
                    }
                    .buttonStyle(.pressable)
                    .disabled(isRunning)
                }
            }
            .padding(.horizontal, 14)
        }
        .padding(.vertical, 8)
    }

    private var diagnosticTint: Color {
        config.target.isManagedHost ? accent : Theme.sky
    }

    /// Quick commands, tailored per target.
    private var diagnostics: [String] {
        config.target == .superserve
            ? ["uname -a", "ls -la", "python3 -V", "node -v", "pip list", "df -h"]
            : ["pwd", "ls -la", "uptime", "whoami", "df -h"]
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            Text(config.target.isManagedHost ? "⟩" : "$")
                .font(Theme.mono(14, .bold))
                .foregroundStyle(accent)
                .contentTransition(.opacity)

            TextField(config.target == .superserve ? "sandbox command…" : "command…", text: $command, axis: .vertical)
                .font(Theme.mono(13.5))
                .foregroundStyle(Theme.textPrimary)
                .tint(accent)
                .lineLimit(1...4)
                .focused($isInputFocused)
                .submitLabel(.go)
                .onSubmit { run(command) }

            Button {
                run(command)
            } label: {
                Group {
                    if isRunning {
                        ProgressView().tint(accent)
                    } else {
                        Image(systemName: "play.fill")
                            .foregroundStyle(Theme.bgPrimary)
                    }
                }
                .font(.system(size: 13, weight: .bold))
                .frame(width: 36, height: 36)
                .background(command.trimmingCharacters(in: .whitespaces).isEmpty && !isRunning ? Theme.bgElevated : accent, in: Circle())
                .overlay(Circle().strokeBorder(Theme.border))
                .shadow(color: command.trimmingCharacters(in: .whitespaces).isEmpty ? .clear : accent.opacity(0.4), radius: 10, y: 3)
            }
            .buttonStyle(.pressable(scale: 0.88))
            .disabled(isRunning || command.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial.opacity(0.5))
    }

    // MARK: - Actions

    private func run(_ raw: String) {
        let cmd = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty, !isRunning else { return }
        isRunning = true
        isInputFocused = false
        command = ""
        liveCommand = cmd
        liveOutput = ""
        Haptics.medium()

        Task {
            let result = await viewModel.streamShell(cmd) { chunk, _ in
                Task { @MainActor in
                    liveOutput += chunk
                    // Keep the live buffer bounded for very chatty tools.
                    if liveOutput.count > 20_000 {
                        liveOutput = String(liveOutput.suffix(16_000))
                    }
                }
            }
            history.append(result)
            isRunning = false
            liveOutput = ""
            liveCommand = ""
            if result.isOk { Haptics.success() } else { Haptics.medium() }
        }
    }

    private func refreshHealth() async {
        health = await viewModel.sandboxHealth()
    }

    private func save() {
        config.port = Int(portText) ?? config.port
        viewModel.updateSandboxConfig(config)
        Task { await refreshHealth() }
    }
}

// MARK: - Console entry

private struct ShellEntry: View {
    let result: ShellRunResult
    var accent: Color = Theme.emerald

    /// Output collapses past this many lines behind a "full log" toggle.
    private static let collapsedLineLimit = 8

    @State private var isExpanded = false

    private var lineCount: Int {
        result.output.reduce(into: 1) { count, char in if char == "\n" { count += 1 } }
    }

    private var isCollapsible: Bool { lineCount > Self.collapsedLineLimit }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(result.target.isManagedHost ? "⟩" : "$")
                    .font(Theme.mono(12, .bold))
                    .foregroundStyle(accent)
                Text(result.command)
                    .font(Theme.mono(12, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
            }

            if !result.output.isEmpty {
                Text(result.output)
                    .font(Theme.mono(11))
                    .foregroundStyle(result.stderr.isEmpty && !result.stdout.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                    .lineLimit(isExpanded ? nil : Self.collapsedLineLimit)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isCollapsible {
                    Button {
                        withAnimation(Theme.snap) { isExpanded.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            Text(isExpanded ? "COLLAPSE" : "FULL LOG · \(lineCount) LINES")
                        }
                        .font(Theme.mono(8.5, .heavy))
                        .tracking(0.8)
                        .foregroundStyle(accent)
                    }
                    .buttonStyle(.pressable(scale: 0.97))
                }
            }

            HStack(spacing: 10) {
                Label(
                    result.isOk ? "0" : "\(result.exitCode)",
                    systemImage: result.isOk ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                .font(Theme.mono(9, .heavy))
                .foregroundStyle(result.isOk ? accent : Theme.rose)

                Text("\(result.durationMs)MS")
                Text(result.target.label)
            }
            .font(Theme.mono(9, .semibold))
            .foregroundStyle(Theme.textTertiary)
            .tracking(0.6)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: 0x0C0C10), in: .rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(result.isOk ? accent.opacity(0.22) : Theme.rose.opacity(0.3))
        )
    }
}

// MARK: - Live streaming entry

/// The run currently in flight — output appends chunk by chunk with a blinking
/// cursor until the process exits and it collapses into a `ShellEntry`.
private struct LiveShellEntry: View {
    let command: String
    let output: String
    let accent: Color

    @State private var cursorOn = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(command.isEmpty ? "⟩" : "⟩")
                    .font(Theme.mono(12, .bold))
                    .foregroundStyle(accent)
                Text(command)
                    .font(Theme.mono(12, .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }

            (Text(output)
                + Text(cursorOn ? "█" : " ").foregroundColor(accent))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.6).tint(accent)
                Text("STREAMING…")
                    .font(Theme.mono(8.5, .heavy))
                    .tracking(1)
                    .foregroundStyle(accent)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: 0x0C0C10), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(accent.opacity(0.35)))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.5).repeatForever()) { cursorOn = false }
        }
    }
}

#Preview {
    ShellView(viewModel: ChatViewModel())
        .preferredColorScheme(.dark)
}
