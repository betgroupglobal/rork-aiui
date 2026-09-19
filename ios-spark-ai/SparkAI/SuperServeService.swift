//
//  SuperServeService.swift
//  SparkAI
//
//  Direct REST client for SuperServe cloud sandboxes (Firecracker microVMs).
//  Replaces the flak3dd SSH hop and the Kali container flow: the phone talks
//  straight to SuperServe, so the terminal works off-LAN on cell data.
//
//  Two planes are involved:
//  • Control plane (https://api.superserve.ai, `Authorization: Bearer <key>`)
//    lists sandboxes and drives lifecycle (activate / resume / pause / create).
//  • Data plane (https://sandbox.superserve.ai, `X-Superserve-Sandbox-Id` +
//    `X-Access-Token` minted by activate/resume) runs commands via `POST /exec`
//    and streams them over SSE via `POST /exec/stream`.
//
//  The API key lives only in the Keychain — never in PersistenceStore.
//

import Foundation
import Observation

/// Lifecycle of the pinned SuperServe sandbox.
nonisolated enum SuperServeState: String, Codable, Equatable {
    /// No API key entered yet.
    case unauthenticated
    /// Key present, sandbox paused or not yet contacted.
    case asleep
    /// Activating / resuming.
    case waking
    /// Running and able to take commands.
    case ready
    /// The pinned sandbox id no longer exists.
    case missing
    case failed

    var label: String {
        switch self {
        case .unauthenticated: "NO API KEY"
        case .asleep: "ASLEEP"
        case .waking: "WAKING"
        case .ready: "READY"
        case .missing: "NOT FOUND"
        case .failed: "FAILED"
        }
    }
}

/// A named, saved sandbox the user can switch to in one tap.
nonisolated struct SuperServeEnvironment: Codable, Identifiable, Equatable {
    var id: String { sandboxID }
    var name: String
    var sandboxID: String

    /// Environments seeded on first launch.
    static let defaults: [SuperServeEnvironment] = [
        SuperServeEnvironment(name: "spark", sandboxID: "75be2c5c-0cdd-4a7a-8fd5-6afa194603f8"),
        SuperServeEnvironment(name: "openclaw", sandboxID: "1df7386a-9f61-4f8f-9047-4eaa70b1bd18"),
    ]
}

/// Persisted (non-secret) SuperServe settings.
nonisolated struct SuperServeConfig: Codable, Equatable {
    /// The pinned sandbox this app drives.
    var sandboxID: String = "75be2c5c-0cdd-4a7a-8fd5-6afa194603f8"
    /// Saved environments (name -> sandbox id) for quick switching.
    var environments: [SuperServeEnvironment] = SuperServeEnvironment.defaults
    /// Control-plane base URL.
    var baseURL: String = "https://api.superserve.ai"
    /// Working directory for every command.
    var workingDir: String = "/home/user"
    /// Hard per-command runtime limit, in seconds.
    var timeoutSeconds: Int = 120
    /// Ports published for preview, newest first.
    var publishedPorts: [Int] = []
    /// Preview access for sandboxes this app creates (`public` or `private`).
    var previewAccess: String = "public"

    var isValid: Bool {
        !sandboxID.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var controlURL: URL? {
        URL(string: baseURL.trimmingCharacters(in: .whitespaces))
    }
}

/// A sandbox as reported by the control plane.
nonisolated struct SuperServeSandbox: Codable, Identifiable, Equatable {
    var id: String
    var name: String?
    var status: String?
    var template: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, status
        case template = "template_name"
        case fromTemplate = "from_template"
        case templateAlt = "template"
    }

    init(id: String, name: String? = nil, status: String? = nil, template: String? = nil) {
        self.id = id
        self.name = name
        self.status = status
        self.template = template
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        status = try? container.decodeIfPresent(String.self, forKey: .status)
        template = (try? container.decodeIfPresent(String.self, forKey: .template))
            ?? (try? container.decodeIfPresent(String.self, forKey: .fromTemplate))
            ?? (try? container.decodeIfPresent(String.self, forKey: .templateAlt))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(template, forKey: .template)
    }

    /// True when the control plane reports the VM as running.
    var isActive: Bool {
        let value = (status ?? "").lowercased()
        return value == "active" || value == "running"
    }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return String(id.prefix(8))
    }
}

/// A single lifecycle log line shown in the sandbox sheet.
nonisolated struct SuperServeEvent: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var isOK: Bool
    var timestamp: Date = Date()
}

@MainActor
@Observable
final class SuperServeService {
    static let shared = SuperServeService()

    private static let configKey = "superserve-config"
    private static let keychainAccount = "superserve-api-key"
    /// Data-plane host shared by every sandbox.
    private static let dataHost = "https://sandbox.superserve.ai"

    private(set) var config: SuperServeConfig
    private(set) var state: SuperServeState = .asleep
    private(set) var events: [SuperServeEvent] = []
    private(set) var sandboxes: [SuperServeSandbox] = []
    private(set) var info: SuperServeSandbox?
    private(set) var readySince: Date?
    private(set) var isListing = false
    /// Result of the last "Test now" probe, shown inline in the sheet.
    private(set) var lastTest: ShellRunResult?
    private(set) var isTesting = false

    /// Short-lived data-plane token from activate/resume.
    private var accessToken: String?

    init() {
        var loaded = PersistenceStore.load(SuperServeConfig.self, forKey: Self.configKey) ?? SuperServeConfig()
        // Merge in any newly seeded environments for existing installs.
        for seed in SuperServeEnvironment.defaults where !loaded.environments.contains(where: { $0.sandboxID == seed.sandboxID }) {
            loaded.environments.append(seed)
        }
        config = loaded
        state = hasAPIKey ? .asleep : .unauthenticated
    }

    /// The saved environment matching the pinned sandbox, if any.
    var activeEnvironment: SuperServeEnvironment? {
        config.environments.first { $0.sandboxID == config.sandboxID }
    }

    /// Switches the pinned sandbox to a saved environment.
    func select(_ environment: SuperServeEnvironment) {
        guard environment.sandboxID != config.sandboxID else { return }
        var next = config
        next.sandboxID = environment.sandboxID
        next.publishedPorts = []
        update(next)
        log("Switched to \(environment.name) · \(String(environment.sandboxID.prefix(8)))")
    }

    /// Saves (or renames) an environment for the given sandbox id.
    func saveEnvironment(name: String, sandboxID: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedID = sandboxID.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, !trimmedID.isEmpty else { return }
        var next = config
        next.environments.removeAll { $0.sandboxID == trimmedID }
        next.environments.append(SuperServeEnvironment(name: trimmedName, sandboxID: trimmedID))
        update(next)
    }

    func removeEnvironment(_ environment: SuperServeEnvironment) {
        var next = config
        next.environments.removeAll { $0.sandboxID == environment.sandboxID }
        update(next)
    }

    // MARK: - Credentials

    /// True once an API key is stored in the Keychain.
    var hasAPIKey: Bool {
        !(KeychainService.password(account: Self.keychainAccount) ?? "").isEmpty
    }

    private var apiKey: String? {
        let key = KeychainService.password(account: Self.keychainAccount) ?? ""
        return key.isEmpty ? nil : key
    }

    /// Stores the API key in the Keychain (never in PersistenceStore).
    func setAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        KeychainService.setPassword(trimmed, account: Self.keychainAccount)
        accessToken = nil
        state = trimmed.isEmpty ? .unauthenticated : .asleep
    }

    func clearAPIKey() {
        KeychainService.deletePassword(account: Self.keychainAccount)
        accessToken = nil
        sandboxes = []
        info = nil
        readySince = nil
        state = .unauthenticated
    }

    // MARK: - State helpers

    var isReady: Bool { state == .ready }
    var isBusy: Bool { state == .waking }

    /// Human uptime since the sandbox reported ready.
    var uptimeText: String {
        guard let readySince else { return "—" }
        let seconds = Int(Date().timeIntervalSince(readySince))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }

    func update(_ config: SuperServeConfig) {
        let changedSandbox = config.sandboxID != self.config.sandboxID
        self.config = config
        PersistenceStore.save(config, forKey: Self.configKey)
        if changedSandbox {
            accessToken = nil
            info = nil
            readySince = nil
            state = hasAPIKey ? .asleep : .unauthenticated
        }
    }

    private func log(_ text: String, isOK: Bool = true) {
        events.append(SuperServeEvent(text: text, isOK: isOK))
        if events.count > 60 { events.removeFirst(events.count - 60) }
    }

    func clearEvents() { events.removeAll() }

    // MARK: - Preview URLs

    /// Public preview URL for a port published inside the sandbox.
    nonisolated static func previewURL(port: Int, sandboxID: String) -> URL? {
        URL(string: "https://\(port)-\(sandboxID).sandbox.superserve.ai")
    }

    func previewURL(port: Int) -> URL? {
        Self.previewURL(port: port, sandboxID: config.sandboxID)
    }

    /// Records a published port so the sheet can list and reopen it.
    func publishPort(_ port: Int) {
        guard (1...65535).contains(port) else { return }
        var next = config
        next.publishedPorts.removeAll { $0 == port }
        next.publishedPorts.insert(port, at: 0)
        next.publishedPorts = Array(next.publishedPorts.prefix(12))
        update(next)
        log("Published port \(port)")
    }

    func retirePort(_ port: Int) {
        var next = config
        next.publishedPorts.removeAll { $0 == port }
        update(next)
    }

    // MARK: - Control plane

    private func controlRequest(
        _ path: String,
        method: String = "GET",
        body: [String: Any]? = nil
    ) throws -> URLRequest {
        guard let key = apiKey else { throw SuperServeError.noAPIKey }
        guard let base = config.controlURL, let url = URL(string: path, relativeTo: base) else {
            throw SuperServeError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    /// Lists every sandbox on the team.
    @discardableResult
    func listSandboxes() async -> [SuperServeSandbox] {
        guard hasAPIKey else {
            state = .unauthenticated
            return []
        }
        isListing = true
        defer { isListing = false }

        do {
            let request = try controlRequest("/sandboxes")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(status) else {
                log("List failed · HTTP \(status)", isOK: false)
                return sandboxes
            }
            let decoded = Self.decodeSandboxList(data)
            sandboxes = decoded
            if let match = decoded.first(where: { $0.id == config.sandboxID }) {
                info = match
                if match.isActive, state != .ready { state = .asleep }
            } else if !decoded.isEmpty, state != .ready {
                state = .missing
            }
            return decoded
        } catch {
            log("List failed · \(error.localizedDescription)", isOK: false)
            return sandboxes
        }
    }

    /// Sandbox lists arrive either bare or wrapped in `data`/`sandboxes`.
    nonisolated private static func decodeSandboxList(_ data: Data) -> [SuperServeSandbox] {
        if let direct = try? JSONDecoder().decode([SuperServeSandbox].self, from: data) {
            return direct
        }
        struct Wrapper: Decodable {
            var data: [SuperServeSandbox]?
            var sandboxes: [SuperServeSandbox]?
            var items: [SuperServeSandbox]?
        }
        if let wrapped = try? JSONDecoder().decode(Wrapper.self, from: data) {
            return wrapped.data ?? wrapped.sandboxes ?? wrapped.items ?? []
        }
        return []
    }

    /// Reads current status for the pinned sandbox without changing state.
    @discardableResult
    func refreshStatus() async -> SuperServeState {
        guard hasAPIKey else {
            state = .unauthenticated
            return state
        }
        guard config.isValid else { return state }

        do {
            let request = try controlRequest("/sandboxes/\(config.sandboxID)")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1

            if status == 404 {
                state = .missing
                info = nil
                readySince = nil
                return state
            }
            guard (200..<300).contains(status) else {
                state = .failed
                return state
            }

            let sandbox = try? JSONDecoder().decode(SuperServeSandbox.self, from: data)
            if let sandbox { info = sandbox }

            if sandbox?.isActive == true {
                if state != .ready {
                    state = .ready
                    readySince = readySince ?? Date()
                }
            } else if state != .waking {
                state = .asleep
                readySince = nil
                accessToken = nil
            }
        } catch {
            state = .failed
        }
        return state
    }

    /// Wakes the sandbox (activate, falling back to resume) and mints the
    /// data-plane access token.
    @discardableResult
    func wake() async -> Bool {
        guard hasAPIKey else {
            state = .unauthenticated
            log("Add your SuperServe API key first", isOK: false)
            return false
        }
        guard config.isValid else { return false }
        if state == .waking { return false }

        state = .waking
        clearEvents()
        log("WAKE \(String(config.sandboxID.prefix(8))) · \(config.baseURL)")

        // `activate` is the documented wake path; `resume` covers paused VMs
        // on deployments where activate is not exposed.
        for path in ["activate", "resume"] {
            do {
                let request = try controlRequest("/sandboxes/\(config.sandboxID)/\(path)", method: "POST")
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1

                if status == 404 {
                    // 404 on activate may mean "no such route"; only treat a
                    // missing sandbox as terminal after both attempts.
                    if path == "resume" {
                        state = .missing
                        log("Sandbox \(config.sandboxID) not found", isOK: false)
                        return false
                    }
                    continue
                }

                if (200..<300).contains(status) {
                    accessToken = Self.extractToken(data, response: response)
                    if let sandbox = try? JSONDecoder().decode(SuperServeSandbox.self, from: data) {
                        info = sandbox
                    }
                    log(path == "activate" ? "Sandbox activated" : "Sandbox resumed")
                    if accessToken == nil {
                        log("No access token returned — using API key on the data plane")
                    }
                    state = .ready
                    readySince = Date()
                    await refreshStatus()
                    if state != .ready {
                        state = .ready
                        readySince = readySince ?? Date()
                    }
                    log("SANDBOX READY\(info?.template.map { " · \($0)" } ?? "")")
                    Haptics.success()
                    return true
                }

                if path == "resume" {
                    let detail = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
                    log("Wake failed · \(detail.prefix(160))", isOK: false)
                }
            } catch let error as SuperServeError {
                log(error.detail, isOK: false)
                state = .failed
                return false
            } catch {
                log("Wake failed · \(error.localizedDescription)", isOK: false)
            }
        }

        state = .failed
        return false
    }

    /// Pauses the sandbox so compute stops being billed.
    func sleep() async {
        guard hasAPIKey, config.isValid, state != .waking else { return }
        log("PAUSING \(String(config.sandboxID.prefix(8)))")
        do {
            let request = try controlRequest("/sandboxes/\(config.sandboxID)/pause", method: "POST")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if (200..<300).contains(status) {
                log("Sandbox paused — compute billing stopped")
            } else {
                let detail = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
                log("Pause reported: \(detail.prefix(160))", isOK: false)
            }
        } catch {
            log("Pause failed · \(error.localizedDescription)", isOK: false)
        }
        accessToken = nil
        readySince = nil
        state = .asleep
        Haptics.medium()
    }

    /// Creates a fresh sandbox and pins it — the recovery path when the
    /// configured sandbox has been deleted.
    func createSandbox(name: String = "spark-ai") async -> Bool {
        guard hasAPIKey else {
            state = .unauthenticated
            return false
        }
        state = .waking
        log("Creating a new sandbox…")
        do {
            let request = try controlRequest("/sandboxes", method: "POST", body: [
                "name": name,
                "preview_access": config.previewAccess,
            ])
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(status),
                  let sandbox = try? JSONDecoder().decode(SuperServeSandbox.self, from: data) else {
                let detail = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
                log("Create failed · \(detail.prefix(160))", isOK: false)
                state = .failed
                return false
            }
            accessToken = Self.extractToken(data, response: response)
            info = sandbox
            var next = config
            next.sandboxID = sandbox.id
            next.publishedPorts = []
            config = next
            PersistenceStore.save(next, forKey: Self.configKey)
            state = .ready
            readySince = Date()
            log("Created \(sandbox.displayName) · \(sandbox.id)")
            Haptics.success()
            await listSandboxes()
            return true
        } catch {
            log("Create failed · \(error.localizedDescription)", isOK: false)
            state = .failed
            return false
        }
    }

    /// Pulls the data-plane token out of a lifecycle response body or header.
    nonisolated private static func extractToken(_ data: Data, response: URLResponse) -> String? {
        if let http = response as? HTTPURLResponse,
           let header = http.value(forHTTPHeaderField: "X-Access-Token"), !header.isEmpty {
            return header
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["access_token", "accessToken", "token", "x_access_token"] {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        if let nested = object["sandbox"] as? [String: Any] {
            for key in ["access_token", "accessToken", "token"] {
                if let value = nested[key] as? String, !value.isEmpty { return value }
            }
        }
        return nil
    }

    // MARK: - Data plane

    private func execRequest(path: String, command: String, stream: Bool) throws -> URLRequest {
        guard let key = apiKey else { throw SuperServeError.noAPIKey }
        guard let url = URL(string: "\(Self.dataHost)\(path)") else { throw SuperServeError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = TimeInterval(max(config.timeoutSeconds, 30) + 30)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.sandboxID, forHTTPHeaderField: "X-Superserve-Sandbox-Id")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let accessToken {
            request.setValue(accessToken, forHTTPHeaderField: "X-Access-Token")
        }
        if stream {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "command": command,
            "working_dir": config.workingDir,
            "timeout_s": config.timeoutSeconds,
        ])
        return request
    }

    /// Streams a command inside the sandbox over SSE, firing `onChunk` per
    /// stdout/stderr chunk. Falls back to the blocking `/exec` route when the
    /// stream is unavailable.
    func run(
        _ command: String,
        onChunk: @escaping @Sendable (String, Bool) -> Void = { _, _ in }
    ) async -> ShellRunResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Self.failure(trimmed, "Empty command", exitCode: 1)
        }
        guard hasAPIKey else {
            return Self.failure(trimmed, "No SuperServe API key — add one in the sandbox sheet")
        }
        guard config.isValid else {
            return Self.failure(trimmed, "No sandbox selected")
        }

        let startedAt = Date()
        var stdout = ""
        var stderr = ""
        var exitCode = 0
        var runError: String?

        do {
            let request = try execRequest(path: "/exec/stream", command: trimmed, stream: true)
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1

            // 503 = paused sandbox: wake it and retry once.
            if status == 503 {
                let woke = await wake()
                if woke { return await runBlocking(trimmed, onChunk: onChunk) }
                return Self.failure(trimmed, "Sandbox is paused and could not be woken")
            }
            guard (200..<300).contains(status) else {
                return await runBlocking(trimmed, onChunk: onChunk)
            }

            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                guard !payload.isEmpty, payload != "[DONE]",
                      let data = payload.data(using: .utf8),
                      let event = try? JSONDecoder().decode(ExecEvent.self, from: data) else { continue }

                if let chunk = event.stdout, !chunk.isEmpty {
                    stdout += chunk
                    onChunk(chunk, false)
                }
                if let chunk = event.stderr, !chunk.isEmpty {
                    stderr += chunk
                    onChunk(chunk, true)
                }
                if let code = event.exitCode { exitCode = code }
                if let message = event.error, !message.isEmpty { runError = message }
            }
        } catch {
            if stdout.isEmpty, stderr.isEmpty {
                return await runBlocking(trimmed, onChunk: onChunk)
            }
            runError = error.localizedDescription
        }

        return ShellRunResult(
            command: trimmed,
            stdout: stdout,
            stderr: stderr,
            exitCode: runError == nil ? exitCode : max(exitCode, 1),
            durationMs: Int(Date().timeIntervalSince(startedAt) * 1000),
            target: .superserve,
            error: runError
        )
    }

    /// Blocking `/exec` fallback — the whole result arrives at once.
    private func runBlocking(
        _ command: String,
        onChunk: @escaping @Sendable (String, Bool) -> Void
    ) async -> ShellRunResult {
        let startedAt = Date()
        do {
            let request = try execRequest(path: "/exec", command: command, stream: false)
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1

            guard (200..<300).contains(status) else {
                let detail = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
                return Self.failure(command, String(detail.prefix(400)))
            }

            let result = try? JSONDecoder().decode(ExecResult.self, from: data)
            let stdout = result?.stdout ?? ""
            let stderr = result?.stderr ?? ""
            if !stdout.isEmpty { onChunk(stdout, false) }
            if !stderr.isEmpty { onChunk(stderr, true) }

            return ShellRunResult(
                command: command,
                stdout: stdout,
                stderr: stderr,
                exitCode: result?.exitCode ?? 0,
                durationMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                target: .superserve,
                error: nil
            )
        } catch let error as SuperServeError {
            return Self.failure(command, error.detail)
        } catch {
            return Self.failure(command, error.localizedDescription)
        }
    }

    /// "Test now": wakes if needed and runs a quick probe so the user can
    /// confirm the key + sandbox work end to end.
    func testConnection() async {
        guard !isTesting else { return }
        isTesting = true
        defer { isTesting = false }
        log("TEST · uname -a")
        let result = await ensureReadyAndRun("uname -a && echo \"user=$(whoami) cwd=$(pwd)\"")
        lastTest = result
        let summary = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        log(result.isOk ? (summary.isEmpty ? "Test passed" : summary) : (result.error ?? summary), isOK: result.isOk)
        if result.isOk { Haptics.success() } else { Haptics.medium() }
    }

    /// Wakes the sandbox if it is cold, then runs — the agent's one-shot path.
    func ensureReadyAndRun(
        _ command: String,
        onChunk: @escaping @Sendable (String, Bool) -> Void = { _, _ in }
    ) async -> ShellRunResult {
        guard hasAPIKey else {
            return Self.failure(command, "No SuperServe API key — add one in the sandbox sheet")
        }
        if !isReady {
            await refreshStatus()
        }
        if !isReady {
            let woke = await wake()
            guard woke else {
                let detail = events.last?.text ?? "Sandbox could not be woken"
                return Self.failure(command, detail)
            }
        }
        return await run(command, onChunk: onChunk)
    }

    nonisolated private static func failure(
        _ command: String,
        _ detail: String,
        exitCode: Int = -1
    ) -> ShellRunResult {
        ShellRunResult(
            command: command, stdout: "", stderr: detail,
            exitCode: exitCode, durationMs: 0, target: .superserve, error: detail
        )
    }

    // MARK: - Wire types

    nonisolated private struct ExecEvent: Decodable {
        var stdout: String?
        var stderr: String?
        var exitCode: Int?
        var error: String?
        var finished: Bool?

        private enum CodingKeys: String, CodingKey {
            case stdout, stderr, error, finished
            case exitCode = "exit_code"
        }
    }

    nonisolated private struct ExecResult: Decodable {
        var stdout: String?
        var stderr: String?
        var exitCode: Int?

        private enum CodingKeys: String, CodingKey {
            case stdout, stderr
            case exitCode = "exit_code"
        }
    }
}

nonisolated enum SuperServeError: Error {
    case noAPIKey
    case badURL

    var detail: String {
        switch self {
        case .noAPIKey: "No SuperServe API key — add one in the sandbox sheet"
        case .badURL: "Invalid SuperServe base URL"
        }
    }
}
