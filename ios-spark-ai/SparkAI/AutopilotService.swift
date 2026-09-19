//
//  AutopilotService.swift
//  SparkAI
//
//  The autonomous mission engine — "auto approve + auto runner". A goal is
//  queued as a Mission; the AI route chain (Edge0 → Featherless → Rork
//  cloud) plans each turn, the agent tools execute for real, and the real
//  results feed the next planning turn until the model reports the mission
//  complete. Every planned action is auto-approved and executed without
//  confirmation; the auto-runner picks up queued missions back-to-back.
//

import Foundation
import Observation

/// Lifecycle of a mission in the autopilot queue.
nonisolated enum MissionStatus: String, Codable, Equatable {
    case queued, running, complete, failed, stopped
}

/// Lifecycle of one streamed step inside a mission.
nonisolated enum MissionStepStatus: String, Codable, Equatable {
    case running, ok, failed, awaiting, skipped
}

/// One streamed step of a mission's execution log.
nonisolated struct MissionStep: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var detail: String
    var status: MissionStepStatus

    init(title: String, detail: String = "", status: MissionStepStatus = .ok) {
        self.id = UUID()
        self.title = title
        self.detail = detail
        self.status = status
    }
}

/// One autonomous mission: a goal, its streamed execution log and outcome.
/// No secrets are persisted here — tool results never contain passwords.
nonisolated struct Mission: Codable, Identifiable, Equatable {
    let id: UUID
    var goal: String
    var status: MissionStatus
    var steps: [MissionStep]
    var summary: String
    var createdAt: Date

    init(goal: String) {
        self.id = UUID()
        self.goal = goal
        self.status = .queued
        self.steps = []
        self.summary = ""
        self.createdAt = Date()
    }

    var isAwaitingApproval: Bool {
        status == .running && steps.contains { $0.status == .awaiting }
    }

    var okCount: Int { steps.filter { $0.status == .ok }.count }
    var errorCount: Int { steps.filter { $0.status == .failed }.count }
}

@MainActor
@Observable
final class AutopilotService {
    static let shared = AutopilotService()

    private static let missionsKey = "autopilot-missions"
    private static let autoApproveKey = "autopilot-auto-approve"
    private static let autoRunKey = "autopilot-auto-run"
    /// Safety rail: a mission can chain at most this many plan→execute hops.
    private static let maxHops = 8

    private(set) var missions: [Mission]
    private(set) var isAutoApprove: Bool
    private(set) var isAutoRun: Bool

    private var engineTask: Task<Void, Never>?
    private var approvalDecisions: [UUID: Bool] = [:]

    private let agent = AgentService()
    private let sandbox = SandboxService()
    private let featherless = FeatherlessService()
    private let edge0 = Edge0Service()
    private let spark = SparkService()
    private let cloud = CloudInferenceService()
    private var resolvedModelID: String?

    var isEngineBusy: Bool { engineTask != nil }

    var hasActiveWork: Bool {
        missions.contains { $0.status == .queued || $0.status == .running }
    }

    private init() {
        var saved = PersistenceStore.load([Mission].self, forKey: Self.missionsKey) ?? []
        // A relaunch kills in-flight work — close it out cleanly.
        for index in saved.indices where saved[index].status == .running {
            saved[index].status = .stopped
            saved[index].summary = "Interrupted by an app relaunch."
            for stepIndex in saved[index].steps.indices
            where saved[index].steps[stepIndex].status == .running
                || saved[index].steps[stepIndex].status == .awaiting {
                saved[index].steps[stepIndex].status = .skipped
            }
        }
        missions = saved
        isAutoApprove = PersistenceStore.load(Bool.self, forKey: Self.autoApproveKey) ?? true
        isAutoRun = PersistenceStore.load(Bool.self, forKey: Self.autoRunKey) ?? true
    }

    // MARK: - Controls

    /// Queues a mission; the auto-runner picks it up when enabled.
    func launch(_ rawGoal: String) {
        let goal = rawGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { return }
        Haptics.medium()
        missions.insert(Mission(goal: goal), at: 0)
        persist()
        if isAutoRun { startEngine() }
    }

    func setAutoApprove(_ on: Bool) {
        Haptics.light()
        isAutoApprove = on
        PersistenceStore.save(on, forKey: Self.autoApproveKey)
    }

    func setAutoRun(_ on: Bool) {
        Haptics.light()
        isAutoRun = on
        PersistenceStore.save(on, forKey: Self.autoRunKey)
        if on { startEngine() }
    }

    /// Jumps a queued mission to the head of the queue and starts the engine.
    func runNow(_ id: UUID) {
        guard !missions.contains(where: { $0.status == .running }) else { return }
        guard let index = missions.firstIndex(where: { $0.id == id }),
              missions[index].status == .queued else { return }
        Haptics.light()
        let mission = missions.remove(at: index)
        missions.insert(mission, at: 0)
        persist()
        startEngine()
    }

    /// Kill switch: cancels the engine and closes out any running mission.
    func stopAll() {
        Haptics.medium()
        engineTask?.cancel()
        engineTask = nil
        approvalDecisions.removeAll()
        for index in missions.indices where missions[index].status == .running {
            missions[index].status = .stopped
            missions[index].summary = "Stopped by the user."
            for stepIndex in missions[index].steps.indices
            where missions[index].steps[stepIndex].status == .running
                || missions[index].steps[stepIndex].status == .awaiting {
                missions[index].steps[stepIndex].status = .skipped
            }
        }
        persist()
    }

    func approve(_ stepID: UUID) {
        Haptics.light()
        approvalDecisions[stepID] = true
    }

    func reject(_ stepID: UUID) {
        Haptics.light()
        approvalDecisions[stepID] = false
    }

    func remove(_ id: UUID) {
        guard missions.first(where: { $0.id == id })?.status != .running else { return }
        missions.removeAll { $0.id == id }
        persist()
    }

    func clearFinished() {
        Haptics.light()
        missions.removeAll { $0.status != .queued && $0.status != .running }
        persist()
    }

    // MARK: - Engine

    private func startEngine() {
        guard engineTask == nil else { return }
        engineTask = Task { [weak self] in
            await self?.engineLoop()
            self?.engineTask = nil
            // A mission may have been queued between the final poll and exit.
            if self?.hasActiveWork == true { self?.startEngine() }
        }
    }

    /// Runs queued missions back-to-back, oldest first, until the queue
    /// drains or the kill switch fires.
    private func engineLoop() async {
        while !Task.isCancelled {
            guard let next = missions.last(where: { $0.status == .queued }) else { break }
            await executeMission(next.id)
        }
    }

    /// The autonomous plan→execute→replan loop. Each hop: the AI route chain
    /// plans one action, it is auto-approved and executed for real, and the
    /// real result is fed back until the model reports the mission complete.
    private func executeMission(_ id: UUID) async {
        guard let mission = missions.first(where: { $0.id == id }) else { return }
        mutateMission(id) {
            $0.status = .running
            $0.steps = []
            $0.summary = ""
        }
        addStep(id, MissionStep(title: "MISSION START", detail: mission.goal))

        var history: [ChatTurn] = [ChatTurn(role: "user", content: Self.missionPrompt(mission.goal))]
        var hop = 0

        while hop < Self.maxHops {
            if Task.isCancelled {
                return finishMission(id, status: .stopped, summary: "Stopped by the user.")
            }
            guard missions.first(where: { $0.id == id })?.status == .running else { return }

            let planStartedAt = Date()
            let planningID = addStep(id, MissionStep(title: "PLANNING", detail: "routing through the mesh…", status: .running))
            guard let (reply, route) = await collectReply(history) else {
                updateStep(id, planningID) {
                    $0.status = .failed
                    $0.detail = "no AI route available"
                }
                return finishMission(
                    id,
                    status: .failed,
                    summary: "No inference route available — enable Edge0 or Featherless (or accept cloud chat consent), then relaunch the mission."
                )
            }
            noteRoute(route, startedAt: planStartedAt, success: true)

            let cleanPlan = Self.stripToolTags(reply).trimmingCharacters(in: .whitespacesAndNewlines)
            updateStep(id, planningID) {
                $0.title = "PLAN · \(Self.routeLabel(route))"
                $0.detail = String(cleanPlan.prefix(180))
                $0.status = .ok
            }

            let calls = AgentService.parseToolCalls(from: reply)
            guard !calls.isEmpty else {
                // The model replied without tools — the mission is done.
                let summary = cleanPlan
                    .replacingOccurrences(of: "MISSION COMPLETE:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                addStep(id, MissionStep(title: "MISSION COMPLETE", detail: String(summary.prefix(180))))
                return finishMission(id, status: .complete, summary: summary.isEmpty ? "Mission finished." : summary)
            }

            history.append(ChatTurn(role: "assistant", content: String(reply.prefix(4000))))

            var resultBlocks: [String] = []
            for call in calls {
                if Task.isCancelled {
                    return finishMission(id, status: .stopped, summary: "Stopped by the user.")
                }
                guard missions.first(where: { $0.id == id })?.status == .running else { return }

                // With auto-approve off, every planned action parks here for
                // an explicit human yes/no on the step card.
                if !isAutoApprove {
                    let gateID = addStep(id, MissionStep(
                        title: "APPROVAL · \(call.name)",
                        detail: String(call.arguments.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180)),
                        status: .awaiting
                    ))
                    let approved = await waitForApproval(gateID)
                    if Task.isCancelled {
                        return finishMission(id, status: .stopped, summary: "Stopped by the user.")
                    }
                    if !approved {
                        updateStep(id, gateID) { $0.status = .skipped }
                        resultBlocks.append("[\(call.name) → SKIPPED] rejected by operator")
                        continue
                    }
                    updateStep(id, gateID) { $0.detail = "approved — executing" }
                }

                let execStartedAt = Date()
                let execID = addStep(id, MissionStep(
                    title: "EXEC · \(call.name)",
                    detail: String(call.arguments.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180)),
                    status: .running
                ))
                let run = await agent.execute(call, sandbox: sandbox, featherless: featherless)
                updateStep(id, execID) {
                    $0.status = run.isOK ? .ok : .failed
                    $0.detail = Self.truncate("\(run.durationMs)ms\n\(run.result)")
                }
                noteToolRoute(call.name, startedAt: execStartedAt, success: run.isOK)
                resultBlocks.append("[\(run.name) → \(run.isOK ? "OK" : "ERROR")]\(run.arguments.isEmpty ? "" : " \(run.arguments)")\n\(run.result)")
            }

            history.append(
                ChatTurn(
                    role: "user",
                    content: "TOOL RESULTS (real execution — never fabricate these):\n\n" + resultBlocks.joined(separator: "\n\n")
                )
            )
            hop += 1
        }

        finishMission(
            id,
            status: .failed,
            summary: "Reached the \(Self.maxHops)-action autopilot limit. Relaunch the mission to continue where it left off."
        )
    }

    // MARK: - AI route chain

    /// Agent prompt plus the autopilot directive — every tool call the model
    /// emits is auto-approved and executed for real.
    private var systemPrompt: String {
        AgentService.systemPrompt + "\n\n" + Self.autopilotDirective
    }

    private static let autopilotDirective = """
    AUTOPILOT DIRECTIVE:
    You are executing a mission autonomously — every tool call you emit is \
    auto-approved and run for real. Each turn, emit exactly one tool call \
    that advances the mission. When the mission is done (or impossible with \
    the available tools), reply starting with "MISSION COMPLETE:" followed \
    by a short factual report. Never ask for permission. Never fabricate results.
    """

    private static func missionPrompt(_ goal: String) -> String {
        """
        MISSION — execute autonomously: \(goal)

        Start acting now. One tool call per reply; reply "MISSION COMPLETE: <report>" when the goal is reached or impossible.
        """
    }

    /// Tries the route chain in order: self-hosted Edge0 → self-hosted
    /// Spark vLLM (abliterated NVFP4) → Featherless → Rork AI cloud
    /// (chat-consent gated). Returns the first route that produced content.
    private func collectReply(_ history: [ChatTurn]) async -> (String, InferenceRoute)? {
        if edge0.isConfigured,
           let text = await collect(edge0.stream(history: history, systemPrompt: systemPrompt)) {
            return (text, .edge0)
        }
        if spark.isConfigured,
           let text = await collect(spark.stream(history: history, systemPrompt: systemPrompt)) {
            return (text, .spark)
        }
        if featherless.isConfigured, let model = await resolvedFeatherlessModel(),
           let text = await collect(featherless.stream(history: history, model: model, systemPrompt: systemPrompt)) {
            return (text, .featherless)
        }
        if cloud.isConfigured, CloudConsent.isAccepted(.chat),
           let text = await collect(cloud.stream(history: history, systemPrompt: systemPrompt)) {
            return (text, .cloud)
        }
        return nil
    }

    /// Drains a streaming route into a single reply, tolerating mid-stream
    /// failures by keeping whatever arrived.
    private func collect(_ stream: AsyncThrowingStream<CloudStreamEvent, Error>) async -> String? {
        var content = ""
        do {
            for try await event in stream {
                if case .content(let delta) = event { content += delta }
            }
        } catch {
            return content.isEmpty ? nil : content
        }
        return content.isEmpty ? nil : content
    }

    private func resolvedFeatherlessModel() async -> String? {
        if let resolvedModelID { return resolvedModelID }
        if let envModel = featherless.envDefaultModelID() {
            resolvedModelID = envModel
            return envModel
        }
        guard let models = try? await featherless.fetchModels() else { return nil }
        resolvedModelID = featherless.resolveDefaultModelID(from: models)
        return resolvedModelID
    }

    // MARK: - Approval gates

    /// Parks until the operator answers the gate, auto-approve is switched
    /// back on, or the engine is cancelled.
    private func waitForApproval(_ stepID: UUID) async -> Bool {
        while !Task.isCancelled {
            if let decision = approvalDecisions[stepID] {
                approvalDecisions[stepID] = nil
                return decision
            }
            if isAutoApprove { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    // MARK: - Helpers

    private func mutateMission(_ id: UUID, _ mutate: (inout Mission) -> Void) {
        guard let index = missions.firstIndex(where: { $0.id == id }) else { return }
        mutate(&missions[index])
        persist()
    }

    @discardableResult
    private func addStep(_ missionID: UUID, _ step: MissionStep) -> UUID {
        mutateMission(missionID) { $0.steps.append(step) }
        return step.id
    }

    private func updateStep(_ missionID: UUID, _ stepID: UUID, _ mutate: (inout MissionStep) -> Void) {
        mutateMission(missionID) { mission in
            guard let index = mission.steps.firstIndex(where: { $0.id == stepID }) else { return }
            mutate(&mission.steps[index])
        }
    }

    private func finishMission(_ id: UUID, status: MissionStatus, summary: String) {
        mutateMission(id) { mission in
            mission.status = status
            mission.summary = summary
            for index in mission.steps.indices
            where mission.steps[index].status == .running || mission.steps[index].status == .awaiting {
                mission.steps[index].status = status == .stopped ? .skipped : .failed
            }
        }
        if status == .complete || status == .failed { Haptics.medium() }
    }

    private func persist() {
        PersistenceStore.save(Array(missions.prefix(30)), forKey: Self.missionsKey)
    }

    private func noteRoute(_ route: InferenceRoute, startedAt: Date, success: Bool) {
        TelemetryViewModel.shared.noteRouteActivity(
            endpointName: Self.routeEndpointName(route),
            latencyMs: Date().timeIntervalSince(startedAt) * 1000,
            success: success
        )
    }

    /// Maps agent tools to the telemetry mesh endpoints they exercise.
    private func noteToolRoute(_ tool: String, startedAt: Date, success: Bool) {
        let endpoint: String
        switch tool {
        case "bash": endpoint = "Sandbox Runner"
        case "list_models": endpoint = "Featherless Cloud"
        case "signup_form", "live_run", "mission": endpoint = "Form Automation"
        default: endpoint = "Rork AI Cloud"
        }
        TelemetryViewModel.shared.noteRouteActivity(
            endpointName: endpoint,
            latencyMs: Date().timeIntervalSince(startedAt) * 1000,
            success: success
        )
    }

    private static func routeLabel(_ route: InferenceRoute) -> String {
        switch route {
        case .edge0: "EDGE0"
        case .spark: "SPARK NVFP4"
        case .featherless: "FEATHERLESS"
        case .cloud: "RORK CLOUD"
        case .local: "LOCAL"
        }
    }

    private static func routeEndpointName(_ route: InferenceRoute) -> String {
        switch route {
        case .edge0: "Edge0 Workstation"
        case .spark: "Spark Direct LAN"
        case .featherless: "Featherless Cloud"
        case .cloud: "Rork AI Cloud"
        case .local: "Spark Direct LAN"
        }
    }

    /// Removes tool markup so plan text reads as plain prose.
    nonisolated private static func stripToolTags(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"<tool[\s\S]*?</tool>|<run>[\s\S]*?</run>"#) else {
            return text
        }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )
    }

    private static func truncate(_ text: String, head: Int = 260) -> String {
        guard text.count > head else { return text }
        return String(text.prefix(head)) + " …"
    }
}
