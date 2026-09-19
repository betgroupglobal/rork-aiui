//
//  ChatView.swift
//  SparkAI
//

import SwiftUI

struct ChatView: View {
    @State private var viewModel = ChatViewModel()
    @State private var showSessions = false
    @State private var showModels = false
    @State private var showShell = false
    @State private var showForms = false
    @State private var showAutopilot = false
    @State private var rainEnabled = true
    @State private var input = ""
    @State private var pendingSendText: String?
    @State private var showCloudDisclosure = false

    var body: some View {
        ZStack {
            Theme.bgPrimary.ignoresSafeArea()

            if rainEnabled {
                MatrixRainView()
                    .opacity(0.32)
                    .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                header

                if viewModel.messages.isEmpty {
                    emptyState
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else {
                    messageList
                        .transition(.opacity)
                }

                InputDock(
                    text: $input,
                    isStreaming: viewModel.isStreaming || viewModel.isAgentWorking,
                    onSend: send,
                    onStop: { viewModel.stopStreaming() },
                    isAgentMode: viewModel.isAgentMode,
                    onToggleAgent: { viewModel.toggleAgentMode() }
                )
            }
        }
        .animation(Theme.reveal, value: viewModel.messages.isEmpty)
        .toolbarBackground(Theme.bgPrimary, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .sheet(isPresented: $showSessions) {
            SessionsSheet(viewModel: viewModel)
                .presentationDetents([.medium, .large])
                .presentationBackground(Theme.bgSurface)
        }
        .sheet(isPresented: $showModels) {
            ModelPickerSheet(viewModel: viewModel)
                .presentationDetents([.medium, .large])
                .presentationBackground(Theme.bgSurface)
                .presentationContentInteraction(.scrolls)
        }
        .sheet(isPresented: $showShell) {
            ShellView(viewModel: viewModel)
                .presentationDetents([.large])
                .presentationBackground(Theme.bgPrimary)
        }
        .sheet(isPresented: $showForms) {
            FormAutomationView()
                .presentationDetents([.large])
                .presentationBackground(Theme.bgPrimary)
        }
        .sheet(isPresented: $showAutopilot) {
            AutopilotView()
                .presentationDetents([.large])
                .presentationBackground(Theme.bgPrimary)
        }
        .alert(
            "Send to third-party AI?",
            isPresented: $showCloudDisclosure,
            presenting: pendingSendText
        ) { text in
            Button("Cancel", role: .cancel) { pendingSendText = nil }
            Button("Send") {
                CloudConsent.accept(.chat)
                pendingSendText = nil
                send(text)
            }
        } message: { _ in
            Text("To generate a reply, your messages are sent to and processed by external AI services (Featherless AI and Rork's cloud gateway) under their own privacy policies. The app keeps history only on this device.")
        }
    }

    private var routeLabel: String {
        switch viewModel.activeRoute {
        case .edge0: "EDGE0 · \(viewModel.edge0Config.resolvedModel.uppercased())"
        case .spark: "SPARK · NVFP4 · \(viewModel.sparkConfig.resolvedModel.uppercased())"
        case .featherless: "FEATHERLESS · \(viewModel.activeModelShortName.uppercased())"
        case .cloud: "RORK AI CLOUD · LING 3.0"
        case .local: "GB10 · ABLITERATED LOCAL"
        }
    }

    private var routeColor: Color {
        switch viewModel.activeRoute {
        case .edge0: Theme.emerald
        case .spark: Theme.amber
        case .featherless: Theme.blue
        case .cloud: Theme.sky
        case .local: Theme.amber
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 10) {
            Button { showSessions = true } label: {
                IconChip(systemName: "rectangle.stack")
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Sessions")

            Button { showModels = true } label: {
                HStack(spacing: 9) {
                    SparkMonogram(size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SPARK AI")
                            .font(Theme.display(15, .bold))
                            .tracking(1.5)
                            .foregroundStyle(Theme.textPrimary)
                        HStack(spacing: 5) {
                            Circle()
                                .fill(routeColor)
                                .frame(width: 5, height: 5)
                                .shadow(color: routeColor.opacity(0.9), radius: 3)
                            Text(routeLabel)
                                .font(Theme.mono(9, .semibold))
                                .foregroundStyle(routeColor)
                                .tracking(1)
                                .lineLimit(1)
                                .contentTransition(.numericText())
                        }
                    }
                }
            }
            .buttonStyle(.pressable(scale: 0.97))
            .disabled(viewModel.isStreaming)
            .animation(Theme.snap, value: viewModel.activeRoute)

            Spacer(minLength: 4)

            Button { showAutopilot = true } label: {
                IconChip(systemName: "paperplane.fill", tint: Theme.amber, isActive: AutopilotService.shared.hasActiveWork)
                    .symbolEffect(.pulse, isActive: AutopilotService.shared.hasActiveWork)
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Autopilot")

            Button { showShell = true } label: {
                IconChip(systemName: "terminal.fill", tint: Theme.emerald, isActive: true)
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Auto Bash shell")

            Button { showForms = true } label: {
                IconChip(systemName: "list.bullet.clipboard.fill", tint: Theme.sky, isActive: true)
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Form automation")

            Button {
                withAnimation(Theme.snap) { rainEnabled.toggle() }
            } label: {
                IconChip(systemName: rainEnabled ? "sparkles" : "sparkles.slash", tint: Theme.blue, isActive: rainEnabled)
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(rainEnabled ? "Hide ambient rain" : "Show ambient rain")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial.opacity(0.4))
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [.clear, routeColor.opacity(0.5), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(height: 1)
                .opacity(viewModel.isStreaming || viewModel.isAgentWorking ? 1 : 0.35)
                .animation(Theme.snap, value: viewModel.isStreaming)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()
            SparkMark(size: 96)
                .entrance(delay: 0.05, offset: 20)

            Text("SPARK AI")
                .font(Theme.display(26, .bold))
                .tracking(4)
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 8)
                .entrance(delay: 0.15)

            Text("Self-hosted abliterated intelligence with live tools, a real shell and autonomous missions.")
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 8)
                .padding(.horizontal, 24)
                .entrance(delay: 0.22)

            HStack(spacing: 8) {
                routePill("EDGE0", Theme.emerald)
                routePill("SPARK NVFP4", Theme.amber)
                routePill("FEATHERLESS", Theme.blue)
                routePill("CLOUD", Theme.sky)
            }
            .padding(.top, 16)
            .entrance(delay: 0.3)

            SuggestionStrip(
                onSelect: { send($0) },
                disabled: viewModel.isStreaming
            )
            .padding(.top, 22)
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    private func routePill(_ label: String, _ tint: Color) -> some View {
        Text(label)
            .font(Theme.mono(8.5, .bold))
            .tracking(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.1), in: .capsule)
            .overlay(Capsule().strokeBorder(tint.opacity(0.3)))
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(viewModel.messages) { message in
                        ChatBubble(message: message, onRunInBash: { command in
                            Task { await viewModel.runShellInChat(command) }
                        })
                        .id(message.id)
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: message.role == .user ? .bottomTrailing : .bottomLeading)),
                                removal: .opacity
                            )
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .animation(Theme.reveal, value: viewModel.messages.count)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: viewModel.messages.last?.content ?? "") { _, _ in
                withAnimation(.snappy(duration: 0.2)) {
                    proxy.scrollTo(viewModel.messages.last?.id, anchor: .bottom)
                }
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                withAnimation(Theme.reveal) {
                    proxy.scrollTo(viewModel.messages.last?.id, anchor: .bottom)
                }
            }
        }
    }

    private func send(_ text: String) {
        guard !text.isEmpty else { return }
        guard CloudConsent.isAccepted(.chat) else {
            pendingSendText = text
            showCloudDisclosure = true
            return
        }
        input = ""
        viewModel.send(text)
    }
}

// MARK: - Sessions sheet

private struct SessionsSheet: View {
    let viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SESSIONS")
                    .font(Theme.display(18, .bold))
                    .tracking(1.5)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    Haptics.light()
                    viewModel.newSession()
                    dismiss()
                } label: {
                    Label("New", systemImage: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.blue)
                }
            }
            .padding(20)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(viewModel.sessions.enumerated()), id: \.element.id) { index, session in
                        SessionRow(
                            session: session,
                            isActive: session.id == viewModel.activeSessionID
                        ) {
                            viewModel.selectSession(session.id)
                            dismiss()
                        }
                        .entrance(delay: min(Double(index) * 0.04, 0.4), offset: 10)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

private struct SessionRow: View {
    let session: ChatSession
    let isActive: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text("\(session.messages.count) messages · \(session.createdAt.formatted(.relative(presentation: .named)))")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                if isActive {
                    Text("ACTIVE")
                        .font(Theme.mono(9, .heavy))
                        .foregroundStyle(Theme.blue)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Theme.blueDim, in: .capsule)
                }
            }
            .padding(14)
            .background(isActive ? Theme.bgElevated : Theme.bgSurface, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(isActive ? Theme.blue.opacity(0.4) : Theme.border))
        }
        .buttonStyle(.pressable(scale: 0.98))
    }
}

// MARK: - Model picker sheet (Featherless abliterated catalog)

private struct ModelPickerSheet: View {
    let viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var edgeConfig = Edge0Config()
    @State private var portText = ""
    @State private var sparkConfig = SparkConfig()
    @State private var sparkPortText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("ABLITERATED MODELS")
                    .font(Theme.display(18, .bold))
                    .tracking(1.5)
                    .foregroundStyle(Theme.textPrimary)
                Text("Edge0 · Spark vLLM NVFP4 · live Featherless catalog")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(20)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    edgeSection
                    sparkSection
                    catalogContent
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .onAppear {
            edgeConfig = viewModel.edge0Config
            portText = String(edgeConfig.port)
            sparkConfig = viewModel.sparkConfig
            sparkPortText = String(sparkConfig.port)
        }
        .task { await viewModel.loadModelCatalog() }
    }

    // MARK: Self-hosted Edge0 (edge0 serve)

    private var edgeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Self-Hosted Edge0")
                        .font(Theme.display(15, .bold))
                        .foregroundStyle(Theme.emerald)
                    Text("Edge0-35B-A3B-preview · edge0 serve")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Toggle("", isOn: $edgeConfig.isEnabled)
                    .labelsHidden()
                    .tint(Theme.emerald)
                    .onChange(of: edgeConfig.isEnabled) { _, _ in
                        Haptics.light()
                        saveEdgeConfig()
                    }
            }

            if edgeConfig.isEnabled {
                edgeField("HOST", text: $edgeConfig.host, placeholder: "192.168.1.44")
                    .onChange(of: edgeConfig.host) { _, _ in saveEdgeConfig() }

                HStack(spacing: 10) {
                    edgeField("PORT", text: $portText, placeholder: "8085")
                        .frame(maxWidth: .infinity)
                    edgeField("MODEL", text: $edgeConfig.model, placeholder: "edge0-35b")
                        .frame(maxWidth: .infinity)
                        .onChange(of: edgeConfig.model) { _, _ in saveEdgeConfig() }
                }
                .onChange(of: portText) { _, _ in saveEdgeConfig() }

                Text("Run `edge0 serve --name edge0-35b --port 8085` on your workstation, then point Spark AI at it. When enabled this becomes the primary chat route, falling back to Featherless → Rork cloud → GB10 local.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Theme.bgSurface, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(edgeConfig.isEnabled && edgeConfig.isValid ? Theme.emerald.opacity(0.45) : Theme.border))
    }

    private func edgeField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Theme.mono(9, .heavy))
                .tracking(0.8)
                .foregroundStyle(Theme.textTertiary)
            TextField(placeholder, text: text)
                .font(Theme.mono(13))
                .foregroundStyle(Theme.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(label == "PORT" ? .numberPad : .asciiCapable)
                .padding(10)
                .background(Theme.bgElevated, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
        }
    }

    private func saveEdgeConfig() {
        edgeConfig.port = Int(portText) ?? edgeConfig.port
        viewModel.updateEdge0Config(edgeConfig)
    }

    // MARK: Self-hosted Spark vLLM (abliterated NVFP4, native tool calling)

    private var sparkSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Spark vLLM · GB10")
                        .font(Theme.display(15, .bold))
                        .foregroundStyle(Theme.amber)
                    Text("Abliterated NVFP4 fine-tune · native tool calling")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Toggle("", isOn: $sparkConfig.isEnabled)
                    .labelsHidden()
                    .tint(Theme.amber)
                    .onChange(of: sparkConfig.isEnabled) { _, _ in
                        Haptics.light()
                        saveSparkConfig()
                    }
            }

            if sparkConfig.isEnabled {
                HStack(spacing: 10) {
                    edgeField("HOST", text: $sparkConfig.host, placeholder: "192.168.4.103")
                        .frame(maxWidth: .infinity)
                        .onChange(of: sparkConfig.host) { _, _ in saveSparkConfig() }
                    edgeField("PORT", text: $sparkPortText, placeholder: "8000")
                        .frame(maxWidth: .infinity)
                }
                .onChange(of: sparkPortText) { _, _ in saveSparkConfig() }

                edgeField("MODEL", text: $sparkConfig.model, placeholder: "qwen-abliterated")
                    .onChange(of: sparkConfig.model) { _, _ in saveSparkConfig() }

                HStack {
                    Text("DISABLE THINKING")
                        .font(Theme.mono(9, .heavy))
                        .tracking(0.8)
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Toggle("", isOn: $sparkConfig.disableThinking)
                        .labelsHidden()
                        .tint(Theme.amber)
                        .onChange(of: sparkConfig.disableThinking) { _, _ in saveSparkConfig() }
                }

                Text("vLLM serves your abliterated NVFP4 fine-tune from unified memory (`vllm serve <model> --port 8000`). Route priority: Edge0 → Spark NVFP4 → Featherless → Rork cloud → GB10 local. In Agent Mode this route uses native OpenAI tool calling with parallel multi-hop execution.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Theme.bgSurface, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(sparkConfig.isEnabled && sparkConfig.isValid ? Theme.amber.opacity(0.45) : Theme.border))
    }

    private func saveSparkConfig() {
        sparkConfig.port = Int(sparkPortText) ?? sparkConfig.port
        viewModel.updateSparkConfig(sparkConfig)
    }

    // MARK: Featherless catalog

    @ViewBuilder
    private var catalogContent: some View {
        if viewModel.isCatalogLoading {
            VStack(spacing: 12) {
                ProgressView()
                    .tint(Theme.blue)
                Text("Probing Featherless catalog…")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 48)
        } else if let error = viewModel.catalogError, viewModel.abliteratedModels.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.amber)
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 48)
        } else if viewModel.abliteratedModels.isEmpty {
            Text("No abliterated models found in the catalog — falling back to capable open-weight models.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 24)
        } else {
            VStack(spacing: 8) {
                ForEach(viewModel.abliteratedModels) { model in
                    ModelRow(
                        model: model,
                        isSelected: model.id == viewModel.selectedModelID
                            || (viewModel.selectedModelID == nil && model.id == viewModel.activeModelID)
                    ) {
                        Haptics.light()
                        viewModel.selectModel(model.id)
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct ModelRow: View {
    let model: FeatherlessModel
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.shortName)
                        .font(Theme.mono(14, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(model.id)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
                Text(contextLabel)
                    .font(Theme.mono(9, .heavy))
                    .foregroundStyle(Theme.sky)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.bgElevated, in: .capsule)
                    .overlay(Capsule().strokeBorder(Theme.border))
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? Theme.blue : Theme.textTertiary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(14)
            .background(isSelected ? Theme.bgElevated : Theme.bgSurface, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(isSelected ? Theme.blue.opacity(0.4) : Theme.border))
        }
        .buttonStyle(.pressable(scale: 0.98))
    }

    private var contextLabel: String {
        model.contextLength >= 1000 ? "\(model.contextLength / 1000)K" : "\(model.contextLength)"
    }
}

#Preview {
    ChatView()
        .preferredColorScheme(.dark)
}
