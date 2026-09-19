//
//  ChatViewModel.swift
//  SparkAI
//

import SwiftUI

@Observable
@MainActor
final class ChatViewModel {
    private static let sessionsKey = "chat-sessions"
    private static let activeSessionKey = "chat-active-session"
    private static let modelKey = "chat-selected-model"
    private static let agentModeKey = "chat-agent-mode"

    private(set) var sessions: [ChatSession]
    private(set) var activeSessionID: UUID
    private(set) var isStreaming = false
    private(set) var activeRoute: InferenceRoute = .featherless
    private(set) var isAgentMode = false
    private(set) var selectedModelID: String?
    private(set) var abliteratedModels: [FeatherlessModel] = []
    private(set) var isCatalogLoading = false
    private(set) var catalogError: String?

    private let engine = ChatEngine()
    private let cloud = CloudInferenceService()
    private let featherless = FeatherlessService()
    private let edge0 = Edge0Service()
    private let spark = SparkService()
    private let sandbox = SandboxService()
    private let agent = AgentService()
    private var resolvedDefaultModelID: String?
    private var streamTask: Task<Void, Never>?

    /// True while the whole turn is in flight including agent tool hops —
    /// guards user sends from interleaving with the loop.
    private(set) var isAgentWorking = false
    private static let nativeHopLimit = 4
    private static let textHopLimit = 2

    init() {
        if let saved = PersistenceStore.load([ChatSession].self, forKey: Self.sessionsKey), !saved.isEmpty {
            sessions = saved
            let storedActive = PersistenceStore.load(UUID.self, forKey: Self.activeSessionKey)
            activeSessionID = saved.contains(where: { $0.id == storedActive }) ? storedActive! : saved[0].id
        } else {
            let initial = ChatSession(title: "New Session", createdAt: Date(), messages: [])
            sessions = [initial]
            activeSessionID = initial.id
        }
        selectedModelID = PersistenceStore.load(String.self, forKey: Self.modelKey)
        isAgentMode = PersistenceStore.load(Bool.self, forKey: Self.agentModeKey) ?? false
    }

    var activeSession: ChatSession {
        sessions.first { $0.id == activeSessionID } ?? sessions[0]
    }

    var messages: [ChatMessage] {
        activeSession.messages
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming, !isAgentWorking else { return }

        Haptics.light()

        appendUserMessage(trimmed)
        startStreamingResponse()
    }

    func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        isAgentWorking = false
        finishStreamingMessage()
        Haptics.medium()
    }

    /// Toggles Agent Mode (live tools) and persists the choice.
    func toggleAgentMode() {
        Haptics.light()
        isAgentMode.toggle()
        PersistenceStore.save(isAgentMode, forKey: Self.agentModeKey)
    }

    /// Agent-mode system prompt handed to whichever route serves the turn.
    /// Native tool-calling routes get the function-calling variant.
    private func agentSystemPrompt(nativeTools: Bool) -> String? {
        guard isAgentMode else { return nil }
        return AgentService.systemPrompt(nativeTools: nativeTools)
    }

    func selectSession(_ id: UUID) {
        guard !isStreaming else { return }
        activeSessionID = id
        persist()
    }

    func newSession() {
        guard !isStreaming else { return }
        let session = ChatSession(title: "New Session", createdAt: Date(), messages: [])
        sessions.insert(session, at: 0)
        activeSessionID = session.id
        persist()
    }

    /// Deletes a session; if it was active, activates the first remaining one.
    func deleteSession(_ id: UUID) {
        guard !isStreaming else { return }
        sessions.removeAll { $0.id == id }
        if sessions.isEmpty {
            let session = ChatSession(title: "New Session", createdAt: Date(), messages: [])
            sessions = [session]
            activeSessionID = session.id
        } else if activeSessionID == id {
            activeSessionID = sessions[0].id
        }
        persist()
    }

    // MARK: - Self-hosted Edge0 (Edge0-35B-A3B-preview)

    var edge0Config: Edge0Config { edge0.config }

    /// Persists the self-hosted Edge0 connection config.
    func updateEdge0Config(_ config: Edge0Config) {
        edge0.update(config)
    }

    // MARK: - Self-hosted Spark vLLM (abliterated NVFP4)

    var sparkConfig: SparkConfig { spark.config }

    /// Persists the local vLLM (GB10 NVFP4) connection config.
    func updateSparkConfig(_ config: SparkConfig) {
        spark.update(config)
    }

    /// Lists models currently served by the local vLLM instance.
    func sparkServedModels() async -> [ServedModel] {
        (try? await spark.fetchModels()) ?? []
    }

    // MARK: - Auto Bash Shell (sandbox runner)

    var sandboxConfig: SandboxConfig { sandbox.config }

    /// Persists the sandbox runner connection config.
    func updateSandboxConfig(_ config: SandboxConfig) {
        sandbox.update(config)
    }

    /// Probes the sandbox runner's health for the terminal drawer.
    func sandboxHealth() async -> SandboxService.Status {
        await sandbox.checkHealth()
    }

    /// Executes a shell command on the sandbox runner, reporting activity
    /// into the telemetry mesh view.
    func executeShell(_ command: String) async -> ShellRunResult {
        Haptics.medium()
        let startedAt = Date()
        let result = await sandbox.execute(command: command)
        noteRoute("Sandbox Runner", startedAt: startedAt, success: result.isOk)
        return result
    }

    /// Streams a shell command on the active target, firing `onChunk` for each
    /// stdout/stderr chunk as it lands. The SANDBOX target runs in the
    /// SuperServe cloud and is woken first if it is asleep.
    func streamShell(
        _ command: String,
        onChunk: @escaping @Sendable (String, Bool) -> Void
    ) async -> ShellRunResult {
        let startedAt = Date()
        let result: ShellRunResult
        if sandbox.config.target == .superserve {
            result = await SuperServeService.shared.ensureReadyAndRun(command, onChunk: onChunk)
            noteRoute("SuperServe Sandbox", startedAt: startedAt, success: result.isOk)
        } else {
            result = await sandbox.stream(command: command, onChunk: onChunk)
            noteRoute("Sandbox Runner", startedAt: startedAt, success: result.isOk)
        }
        return result
    }

    /// Runs a shell command from chat ("Run in Bash" / auto-bash) and appends
    /// the result as a terminal-styled message in the transcript.
    func runShellInChat(_ command: String) async {
        let result = await executeShell(command)
        mutateActiveSession { session in
            session.messages.append(
                ChatMessage(role: .assistant, content: "", timestamp: Date(), shellResult: result)
            )
        }
    }

    /// Auto-Bash: when enabled (and Agent Mode is off — the agent loop owns
    /// commands then), executes shell commands found in the latest assistant
    /// reply via the sandbox runner.
    private func autoBashIfNeeded() async {
        guard sandbox.config.autoRun, !isAgentMode, !Task.isCancelled, !isStreaming else { return }
        let last = messages.last
        guard last?.role == .assistant, last?.shellResult == nil, let content = last?.content else { return }
        for command in SandboxService.extractShellCommands(from: content) {
            await runShellInChat(command)
        }
    }

    // MARK: - Model catalog (Featherless abliterated models)

    var activeModelShortName: String {
        let id = selectedModelID ?? resolvedDefaultModelID ?? featherless.envDefaultModelID()
        return id?.split(separator: "/").last.map(String.init) ?? "AUTO"
    }

    /// The model ID the next request will use (user pick, then resolved default).
    var activeModelID: String? {
        selectedModelID ?? resolvedDefaultModelID ?? featherless.envDefaultModelID()
    }

    /// Loads the live Featherless catalog and resolves the default model.
    func loadModelCatalog() async {
        guard featherless.isConfigured, !isCatalogLoading else { return }
        if !abliteratedModels.isEmpty, resolvedDefaultModelID != nil { return }

        isCatalogLoading = true
        defer { isCatalogLoading = false }

        do {
            let models = try await featherless.fetchModels()
            abliteratedModels = models
                .filter(\.isAbliterated)
                .sorted { $0.shortName.localizedStandardCompare($1.shortName) == .orderedAscending }
            if resolvedDefaultModelID == nil {
                resolvedDefaultModelID = featherless.resolveDefaultModelID(from: models)
            }
            catalogError = nil
        } catch {
            catalogError = "Couldn't reach the Featherless catalog."
        }
    }

    func selectModel(_ id: String) {
        guard id != selectedModelID, !isStreaming else { return }
        Haptics.light()
        selectedModelID = id
        persist()
    }

    // MARK: - Streaming internals

    private func appendUserMessage(_ text: String) {
        mutateActiveSession { session in
            session.messages.append(
                ChatMessage(role: .user, content: text, timestamp: Date())
            )
            if session.messages.count == 1 {
                let title = text.count > 34 ? String(text.prefix(34)) + "…" : text
                session.title = title
            }
        }
    }

    private func startStreamingResponse() {
        let userText = activeSession.messages.last?.content ?? ""
        let history = cloudHistory(endingWith: userText)
        isStreaming = true
        isAgentWorking = true

        streamTask = Task { [weak self] in
            guard let self else { return }
            let nativeCalls = await self.streamRoutedTurn(history, userText: userText)
            await self.autoBashIfNeeded()
            await self.runAgentLoop(depth: 0, nativeCalls: nativeCalls)
            self.isAgentWorking = false
        }
    }

    /// Appends an empty streaming assistant message and runs the route chain:
    /// self-hosted Edge0 (edge0 serve) → self-hosted Spark vLLM (abliterated
    /// NVFP4) → Featherless abliterated inference → Rork AI proxy gateway →
    /// local simulated GB10 engine. Returns the native tool calls streamed
    /// by the serving route (empty for text-protocol routes).
    @discardableResult
    private func streamRoutedTurn(_ history: [ChatTurn], userText: String) async -> [NativeToolCall] {
        guard !Task.isCancelled else { return [] }
        isStreaming = true

        mutateActiveSession { session in
            session.messages.append(
                ChatMessage(role: .assistant, content: "", timestamp: Date(), isStreaming: true)
            )
        }

        let edge0Turn = await streamViaEdge0(history)
        var routed = edge0Turn.routed
        var nativeCalls = edge0Turn.calls

        if !routed {
            let sparkTurn = await streamViaSpark(history)
            routed = sparkTurn.routed
            nativeCalls = sparkTurn.calls
        }
        if !routed { routed = await streamViaFeatherless(history) }
        if !routed { routed = await streamViaCloud(history) }
        if !routed {
            await streamViaLocalEngine(userText)
        }
        return nativeCalls
    }

    /// Agent Mode follow-up loop. Native `tool_calls` (streamed by the Spark
    /// vLLM NVFP4 or Edge0 routes) execute in parallel batches with native
    /// role:"tool" result turns; text-tag calls keep the legacy protocol.
    /// Results feed the next turn, up to the per-mode hop limits.
    private func runAgentLoop(depth: Int, nativeCalls: [NativeToolCall] = []) async {
        guard isAgentMode, !Task.isCancelled else { return }

        if !nativeCalls.isEmpty {
            guard depth < Self.nativeHopLimit else { return }
            // The assistant turn that requested these tools is the latest
            // message; capture its content before tool cards are appended.
            let assistantContent = messages.last?.content ?? ""

            let resultTurns = await executeNativeToolCalls(nativeCalls)

            // Feed results back natively: an assistant turn carrying
            // tool_calls plus one role:"tool" result per call — the shape
            // vLLM and edge0 serve expect for multi-turn tool calling.
            var history = agentHistory()
            history.append(ChatTurn(role: "assistant", content: assistantContent, toolCalls: nativeCalls))
            history.append(contentsOf: resultTurns)

            let nextCalls = await streamRoutedTurn(history, userText: "Continue using the tool results.")
            await runAgentLoop(depth: depth + 1, nativeCalls: nextCalls)
            return
        }

        guard depth < Self.textHopLimit else { return }
        guard !isStreaming else { return }
        guard let last = messages.last,
              last.role == .assistant,
              last.toolRun == nil,
              last.shellResult == nil,
              !last.content.isEmpty else { return }

        let calls = AgentService.parseToolCalls(from: last.content)
        guard !calls.isEmpty else { return }

        var resultBlocks: [String] = []
        for call in calls {
            let run = await agent.execute(call, sandbox: sandbox, featherless: featherless, spark: spark)
            noteToolRoute(run)
            mutateActiveSession { session in
                session.messages.append(
                    ChatMessage(role: .assistant, content: "", timestamp: Date(), toolRun: run)
                )
            }
            resultBlocks.append("[\(run.name) → \(run.isOK ? "OK" : "ERROR")]\(run.arguments.isEmpty ? "" : " \(run.arguments)")\n\(run.result)")
        }

        // Feed the real results back for the next agent turn.
        let resultsTurn = "TOOL RESULTS (real execution — never fabricate these):\n\n"
            + resultBlocks.joined(separator: "\n\n")
        var history = agentHistory()
        history.append(ChatTurn(role: "assistant", content: last.content))
        history.append(ChatTurn(role: "user", content: resultsTurn))

        let nextCalls = await streamRoutedTurn(history, userText: "Continue using the tool results.")
        await runAgentLoop(depth: depth + 1, nativeCalls: nextCalls)
    }

    /// Advanced tool calling: executes a batch of native tool calls — in
    /// parallel when there are several — appending a tool card per run, and
    /// returns the role:"tool" result turns for the follow-up request.
    private func executeNativeToolCalls(_ calls: [NativeToolCall]) async -> [ChatTurn] {
        let runs: [(index: Int, run: ToolRun)] = await withTaskGroup(
            of: (Int, ToolRun).self,
            returning: [(Int, ToolRun)].self
        ) { group in
            for (index, call) in calls.enumerated() {
                group.addTask { [agent, sandbox, featherless, spark] in
                    let run = await agent.execute(
                        AgentToolCall(id: call.id, name: call.name, arguments: call.arguments),
                        sandbox: sandbox,
                        featherless: featherless,
                        spark: spark
                    )
                    return (index, run)
                }
            }
            var collected: [(Int, ToolRun)] = []
            for await result in group { collected.append(result) }
            return collected.sorted { $0.0 < $1.0 }
        }

        var resultTurns: [ChatTurn] = []
        for (index, call) in calls.enumerated() {
            let run = runs.first { $0.index == index }?.run
                ?? ToolRun(name: call.name, arguments: call.arguments, result: "(no result)", isOK: false, durationMs: 0)
            mutateActiveSession { session in
                session.messages.append(
                    ChatMessage(role: .assistant, content: "", timestamp: Date(), toolRun: run)
                )
            }
            noteToolRoute(run)
            resultTurns.append(
                ChatTurn(
                    role: "tool",
                    content: "[\(run.name) → \(run.isOK ? "OK" : "ERROR")] \(run.result)",
                    toolCallID: call.id
                )
            )
        }
        return resultTurns
    }

    /// Reports tool execution activity into the telemetry mesh view.
    private func noteToolRoute(_ run: ToolRun) {
        let startedAt = Date().addingTimeInterval(-Double(run.durationMs) / 1000)
        switch run.name {
        case "bash":
            noteRoute("Sandbox Runner", startedAt: startedAt, success: run.isOK)
        case "list_models":
            noteRoute("Featherless Cloud", startedAt: startedAt, success: run.isOK)
        case "signup_form":
            noteRoute("Form Automation", startedAt: startedAt, success: run.isOK)
        default:
            break
        }
    }

    /// Transcript history for agent turns: real content only (tool cards are
    /// injected explicitly), capped like the cloud history.
    private func agentHistory() -> [ChatTurn] {
        messages
            .dropLast()
            .filter { !$0.content.isEmpty }
            .suffix(12)
            .map { ChatTurn(role: $0.role == .user ? "user" : "assistant", content: $0.content) }
    }

    /// Streams from Featherless. Returns true when the route produced a reply
    /// (or was cancelled mid-stream); false when it should fall back.
    private func streamViaFeatherless(_ history: [ChatTurn]) async -> Bool {
        guard featherless.isConfigured, let model = await resolvedModelID() else { return false }

        var producedContent = false
        let startedAt = Date()
        do {
            for try await event in featherless.stream(history: history, model: model, systemPrompt: agentSystemPrompt(nativeTools: false)) {
                switch event {
                case .reasoning(let delta):
                    appendReasoningDelta(delta)
                case .content(let delta):
                    producedContent = true
                    appendChunk(delta)
                case .toolCalls:
                    break
                }
            }
            guard producedContent else { return false }
            activeRoute = .featherless
            noteRoute("Featherless Cloud", startedAt: startedAt, success: true)
            finishStreamingMessage()
            isStreaming = false
            return true
        } catch {
            if (error as? CancellationError) != nil || Task.isCancelled || producedContent {
                finishStreamingMessage()
                isStreaming = false
                if producedContent { activeRoute = .featherless }
                return true
            }
            noteRoute("Featherless Cloud", startedAt: startedAt, success: false)
            return false
        }
    }

    /// The model for the next request: user selection, then the resolved
    /// default, then the env override (resolving via the catalog once).
    private func resolvedModelID() async -> String? {
        if let selectedModelID { return selectedModelID }
        if let resolvedDefaultModelID { return resolvedDefaultModelID }
        if let envModel = featherless.envDefaultModelID() {
            resolvedDefaultModelID = envModel
            return envModel
        }
        await loadModelCatalog()
        return resolvedDefaultModelID
    }

    /// Streams from the user's self-hosted `edge0 serve` endpoint running
    /// Edge0-35B-A3B-preview (native tool calling when Agent Mode is on).
    private func streamViaEdge0(_ history: [ChatTurn]) async -> (routed: Bool, calls: [NativeToolCall]) {
        guard edge0.isConfigured else { return (false, []) }
        return await streamNativeTurn(history, route: .edge0, endpointName: "Edge0 Workstation") {
            self.edge0.stream(history: history, systemPrompt: self.agentSystemPrompt(nativeTools: true), enableTools: self.isAgentMode)
        }
    }

    /// Streams from the user's self-hosted vLLM on the DGX Spark (GB10)
    /// serving the abliterated NVFP4 fine-tune, with native OpenAI tool
    /// calling when Agent Mode is on.
    private func streamViaSpark(_ history: [ChatTurn]) async -> (routed: Bool, calls: [NativeToolCall]) {
        guard spark.isConfigured else { return (false, []) }
        return await streamNativeTurn(history, route: .spark, endpointName: "Spark Direct LAN") {
            self.spark.stream(history: history, systemPrompt: self.agentSystemPrompt(nativeTools: true), enableTools: self.isAgentMode)
        }
    }

    /// Shared streaming for native tool-calling routes: relays reasoning and
    /// content deltas, assembles streamed `tool_calls` fragments, and applies
    /// the usual fallback semantics. Returns whether the route served the
    /// turn plus any completed native tool calls.
    private func streamNativeTurn(
        _ history: [ChatTurn],
        route: InferenceRoute,
        endpointName: String,
        stream: () -> AsyncThrowingStream<CloudStreamEvent, Error>
    ) async -> (routed: Bool, calls: [NativeToolCall]) {
        var producedContent = false
        var assembler = ToolCallAssembler()
        let startedAt = Date()

        do {
            for try await event in stream() {
                switch event {
                case .reasoning(let delta):
                    appendReasoningDelta(delta)
                case .content(let delta):
                    producedContent = true
                    appendChunk(delta)
                case .toolCalls(let fragments):
                    assembler.absorb(fragments)
                }
            }

            let calls = assembler.calls
            guard producedContent || !calls.isEmpty else { return (false, []) }
            activeRoute = route
            noteRoute(endpointName, startedAt: startedAt, success: true)
            finishStreamingMessage()
            isStreaming = false
            return (true, calls)
        } catch {
            if (error as? CancellationError) != nil || Task.isCancelled || producedContent {
                finishStreamingMessage()
                isStreaming = false
                if producedContent { activeRoute = route }
                return (true, assembler.calls)
            }
            noteRoute(endpointName, startedAt: startedAt, success: false)
            return (false, [])
        }
    }

    /// Streams from the cloud gateway. Returns true when the route produced a
    /// reply (or was cancelled mid-stream); false when it should fall back.
    private func streamViaCloud(_ history: [ChatTurn]) async -> Bool {
        guard cloud.isConfigured else { return false }

        var producedContent = false
        let startedAt = Date()
        do {
            for try await event in cloud.stream(history: history, systemPrompt: agentSystemPrompt(nativeTools: false)) {
                switch event {
                case .reasoning(let delta):
                    appendReasoningDelta(delta)
                case .content(let delta):
                    producedContent = true
                    appendChunk(delta)
                case .toolCalls:
                    break
                }
            }
            guard producedContent else { return false }
            activeRoute = .cloud
            noteRoute("Rork AI Cloud", startedAt: startedAt, success: true)
            finishStreamingMessage()
            isStreaming = false
            return true
        } catch {
            // A cancelled stream is user-intentional; keep what arrived.
            if (error as? CancellationError) != nil || Task.isCancelled || producedContent {
                finishStreamingMessage()
                isStreaming = false
                if producedContent { activeRoute = .cloud }
                return true
            }
            noteRoute("Rork AI Cloud", startedAt: startedAt, success: false)
            return false
        }
    }

    /// Reports real route activity into the telemetry mesh view.
    private func noteRoute(_ endpointName: String, startedAt: Date, success: Bool) {
        TelemetryViewModel.shared.noteRouteActivity(
            endpointName: endpointName,
            latencyMs: Date().timeIntervalSince(startedAt) * 1000,
            success: success
        )
    }

    private func streamViaLocalEngine(_ userText: String) async {
        activeRoute = .local
        let startedAt = Date()
        let reply = engine.reply(for: userText)
        attachReasoning(reply.reasoning)

        let stream = engine.streamReply(for: userText)
        do {
            for try await chunk in stream {
                appendChunk(chunk)
            }
        } catch {
            // Streaming interrupted; keep whatever has arrived.
        }
        finishStreamingMessage()
        isStreaming = false
        noteRoute("Spark Direct LAN", startedAt: startedAt, success: true)
    }
    private func cloudHistory(endingWith userText: String) -> [ChatTurn] {
        let prior = messages.dropLast().suffix(14).filter { !$0.content.isEmpty }.suffix(12).map { message in
            ChatTurn(
                role: message.role == .user ? "user" : "assistant",
                content: message.content
            )
        }
        return prior + [ChatTurn(role: "user", content: userText)]
    }

    private func attachReasoning(_ reasoning: String?) {
        guard let reasoning else { return }
        mutateActiveSession { session in
            session.messages[session.messages.count - 1].reasoning = reasoning
        }
    }

    /// Appends a streamed reasoning fragment to the in-flight message.
    private func appendReasoningDelta(_ delta: String) {
        mutateActiveSession { session in
            let index = session.messages.count - 1
            let current = session.messages[index].reasoning ?? ""
            session.messages[index].reasoning = current + delta
        }
    }

    private func appendChunk(_ chunk: String) {
        mutateActiveSession { session in
            session.messages[session.messages.count - 1].content += chunk
        }
    }

    private func finishStreamingMessage() {
        mutateActiveSession { session in
            session.messages[session.messages.count - 1].isStreaming = false
        }
    }

    private func mutateActiveSession(_ mutate: (inout ChatSession) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == activeSessionID }) else { return }
        mutate(&sessions[index])
        persist()
    }

    // MARK: - Persistence

    /// Persists sessions (bounded) plus the active session and model pick.
    private func persist() {
        let trimmed = sessions
            .suffix(20)
            .map { session -> ChatSession in
                var bounded = session
                if bounded.messages.count > 80 {
                    bounded.messages = Array(bounded.messages.suffix(80))
                }
                return bounded
            }
        PersistenceStore.save(trimmed, forKey: Self.sessionsKey)
        PersistenceStore.save(activeSessionID, forKey: Self.activeSessionKey)
        if let selectedModelID {
            PersistenceStore.save(selectedModelID, forKey: Self.modelKey)
        }
    }
}
