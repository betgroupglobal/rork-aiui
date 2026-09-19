//
//  SandboxService.swift
//  SparkAI
//
//  Ported from flak3dd/aiui — the Auto Bash Shell. Talks to the sandbox
//  runner (default http://127.0.0.1:17330) to execute real shell commands
//  on a Local Mac or DGX Spark GB10 target. Powers the terminal drawer,
//  "Run in Bash" code-block actions and Auto-Bash execution of assistant
//  output.
//

import Foundation

/// Where sandbox commands execute.
nonisolated enum SandboxTarget: String, Codable, CaseIterable {
    case localMac = "local_mac"
    case dgxSpark = "dgx_spark"
    case superserve = "superserve"

    var label: String {
        switch self {
        case .localMac: "LOCAL"
        case .dgxSpark: "GB10"
        case .superserve: "SANDBOX"
        }
    }

    /// Targets that are managed by a provisioning sheet rather than the runner.
    var isManagedHost: Bool {
        self == .superserve
    }
}

/// User-configurable connection to the sandbox runner.
nonisolated struct SandboxConfig: Codable, Equatable {
    var host: String = "127.0.0.1"
    var port: Int = 17330
    var target: SandboxTarget = .localMac
    var workspaceDir: String = "/tmp/spark-sandboxes"
    /// Auto-execute shell commands found in assistant replies.
    var autoRun: Bool = false

    var isValid: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && (1...65535).contains(port)
    }

    var baseURL: URL? {
        URL(string: "http://\(Self.sanitizedHost(host)):\(port)")
    }

    /// Accepts hosts typed as `127.0.0.1`, `mybox.local` or full URLs and
    /// strips scheme/port/path so URL building stays valid.
    static func sanitizedHost(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespaces)
        for prefix in ["http://", "https://"] where host.lowercased().hasPrefix(prefix) {
            host = String(host.dropFirst(prefix.count))
        }
        if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
        if let colon = host.lastIndex(of: ":") { host = String(host[..<colon]) }
        return host
    }
}

/// A completed sandbox execution. Persisted with the chat transcript when
/// a command was run from a reply.
nonisolated struct ShellRunResult: Codable, Equatable {
    var command: String
    var stdout: String
    var stderr: String
    var exitCode: Int
    var durationMs: Int
    var target: SandboxTarget
    var error: String?

    var isOk: Bool { exitCode == 0 && error == nil }
    var output: String { [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n") }
}

nonisolated final class SandboxService {
    private static let configKey = "sandbox-config"
    private static let envID = "spark_ios"

    private(set) var config: SandboxConfig

    init() {
        config = PersistenceStore.load(SandboxConfig.self, forKey: Self.configKey) ?? SandboxConfig()
    }

    /// Persists an updated connection config.
    func update(_ config: SandboxConfig) {
        self.config = config
        PersistenceStore.save(config, forKey: Self.configKey)
    }

    // MARK: - Health

    struct Status: Equatable {
        var isOnline: Bool
        var latencyMs: Int?
        var error: String?
    }

    /// Probes the runner's `/health` endpoint with a 2s timeout.
    func checkHealth() async -> Status {
        guard let url = config.baseURL?.appendingPathComponent("health") else {
            return Status(isOnline: false, latencyMs: nil, error: "Not configured")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2

        let startedAt = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(status) else {
                return Status(isOnline: false, latencyMs: nil, error: "HTTP \(status)")
            }
            let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            return Status(isOnline: true, latencyMs: latencyMs, error: nil)
        } catch {
            return Status(isOnline: false, latencyMs: nil, error: "Offline")
        }
    }

    // MARK: - Execution

    /// Streams a command on the sandbox runner line-by-line via SSE
    /// (`POST /api/sandbox/stream`). Each stdout/stderr chunk fires `onChunk`
    /// as it arrives; the resolved result is returned when the process exits.
    /// Falls back to the batch `execute` path when streaming is unavailable.
    func stream(
        command: String,
        target: SandboxTarget? = nil,
        onChunk: @escaping @Sendable (String, Bool) -> Void
    ) async -> ShellRunResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTarget = target ?? config.target

        guard !trimmed.isEmpty else {
            return ShellRunResult(
                command: trimmed, stdout: "", stderr: "Empty command",
                exitCode: 1, durationMs: 0, target: resolvedTarget, error: "Empty command"
            )
        }
        guard config.isValid, let url = config.baseURL?.appendingPathComponent("api/sandbox/stream") else {
            return ShellRunResult(
                command: trimmed, stdout: "", stderr: "Sandbox runner not configured",
                exitCode: -1, durationMs: 0, target: resolvedTarget, error: "Not configured"
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 900
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "envId": Self.envID,
            "cmd": trimmed,
            "target": resolvedTarget.rawValue,
            "cwd": config.workspaceDir,
        ])

        let startedAt = Date()
        var stdout = ""
        var stderr = ""
        var exitCode = 0
        var runError: String?

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            // Runner without a streaming route -> batch exec fallback.
            guard (200..<300).contains(status) else {
                return await execute(command: trimmed, target: resolvedTarget)
            }

            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                guard !payload.isEmpty, payload != "[DONE]",
                      let data = payload.data(using: .utf8),
                      let event = try? JSONDecoder().decode(StreamEvent.self, from: data) else { continue }

                switch event.type {
                case "stdout":
                    let chunk = event.data ?? ""
                    stdout += chunk
                    onChunk(chunk, false)
                case "stderr":
                    let chunk = event.data ?? ""
                    stderr += chunk
                    onChunk(chunk, true)
                case "exit":
                    exitCode = event.exitCode ?? 0
                case "error":
                    runError = event.data ?? "stream error"
                default:
                    break
                }
            }
        } catch {
            // Nothing arrived before the stream broke -> try the batch route.
            if stdout.isEmpty, stderr.isEmpty {
                return await execute(command: trimmed, target: resolvedTarget)
            }
            runError = error.localizedDescription
        }

        return ShellRunResult(
            command: trimmed,
            stdout: stdout,
            stderr: stderr,
            exitCode: runError == nil ? exitCode : max(exitCode, 1),
            durationMs: Int(Date().timeIntervalSince(startedAt) * 1000),
            target: resolvedTarget,
            error: runError
        )
    }

    private struct StreamEvent: Decodable {
        var type: String
        var data: String?
        var exitCode: Int?
    }

    /// Executes a command on the sandbox runner (`POST /api/sandbox/exec`)
    /// and returns the real stdout/stderr, exit code and latency.
    func execute(command: String, target: SandboxTarget? = nil) async -> ShellRunResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTarget = target ?? config.target

        guard !trimmed.isEmpty else {
            return ShellRunResult(
                command: trimmed, stdout: "", stderr: "Empty command",
                exitCode: 1, durationMs: 0, target: resolvedTarget, error: "Empty command"
            )
        }
        guard config.isValid, let url = config.baseURL?.appendingPathComponent("api/sandbox/exec") else {
            return ShellRunResult(
                command: trimmed, stdout: "", stderr: "Sandbox runner not configured",
                exitCode: -1, durationMs: 0, target: resolvedTarget, error: "Not configured"
            )
        }

        let body: [String: Any] = [
            "envId": Self.envID,
            "cmd": trimmed,
            "target": resolvedTarget.rawValue,
            "cwd": config.workspaceDir,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let startedAt = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1

            guard (200..<300).contains(status) else {
                let detail = String(data: data, encoding: .utf8) ?? ""
                return ShellRunResult(
                    command: trimmed, stdout: "", stderr: detail, exitCode: status,
                    durationMs: durationMs, target: resolvedTarget,
                    error: "Sandbox error HTTP \(status)"
                )
            }

            struct Payload: Decodable {
                var ok: Bool?
                var stdout: String?
                var stderr: String?
                var exitCode: Int?
                var error: String?
            }
            let payload = (try? JSONDecoder().decode(Payload.self, from: data)) ?? Payload()
            let exitCode = payload.exitCode ?? ((payload.ok ?? false) ? 0 : 1)

            return ShellRunResult(
                command: trimmed,
                stdout: payload.stdout ?? "",
                stderr: payload.stderr ?? payload.error ?? "",
                exitCode: exitCode,
                durationMs: durationMs,
                target: resolvedTarget,
                error: payload.error
            )
        } catch {
            let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            return ShellRunResult(
                command: trimmed,
                stdout: "",
                stderr: "Failed to reach sandbox runner at \(config.baseURL?.absoluteString ?? "-"). Is `npm run sandbox` running on the host?",
                exitCode: -1,
                durationMs: durationMs,
                target: resolvedTarget,
                error: error.localizedDescription
            )
        }
    }

    // MARK: - Command extraction (ported from aiui bashShell.ts)

    /// Extracts runnable commands from assistant output: `<run>`/`<bash>`/`<cmd>`
    /// tags, `$ `-prefixed fenced shell blocks, bare fenced shell blocks, and
    /// python/node blocks wrapped as heredocs for the sandbox runner.
    static func extractShellCommands(from text: String) -> [String] {
        var commands: [String] = []
        func append(_ raw: String) {
            let cmd = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cmd.isEmpty, !commands.contains(cmd) else { return }
            commands.append(cmd)
        }
        let fullRange = NSRange(text.startIndex..., in: text)

        // 1. <run>cmd</run>, <bash>cmd</bash>, <cmd>cmd</cmd>
        if let tagRegex = try? NSRegularExpression(
            pattern: #"<(run|bash|cmd)>([\s\S]*?)</\1>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) {
            tagRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let match, let range = Range(match.range(at: 2), in: text) else { return }
                append(String(text[range]))
            }
        }

        // 2. Fenced code blocks, dispatched by language tag.
        if let fenceRegex = try? NSRegularExpression(
            pattern: #"```([A-Za-z0-9_+-]*)[ \t]*\n([\s\S]*?)```"#,
            options: .dotMatchesLineSeparators
        ) {
            fenceRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let match,
                      let langRange = Range(match.range(at: 1), in: text),
                      let bodyRange = Range(match.range(at: 2), in: text) else { return }
                let language = text[langRange].lowercased()
                var body = text[bodyRange].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty, !body.hasPrefix("#") else { return }
                if body.hasPrefix("$ ") { body = String(body.dropFirst(2)) }

                switch language {
                case "bash", "sh", "zsh", "shell":
                    append(body)
                case "python", "py":
                    append("python3 - <<'PY'\n\(body)\nPY")
                case "javascript", "js", "node":
                    append("node - <<'JS'\n\(body)\nJS")
                default:
                    break
                }
            }
        }

        return Array(commands.prefix(3))
    }
}
