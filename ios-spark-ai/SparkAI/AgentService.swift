//
//  AgentService.swift
//  SparkAI
//
//  Ported from flak3dd/aiui — Agent Mode with live tools. The model is
//  instructed to emit explicit tool tags; this service parses them, executes
//  against real backends (sandbox shell, Featherless catalog, HTTP APIs,
//  clock) and returns structured runs whose results are fed back into the
//  conversation for the next turn.
//

import Foundation

/// A tool invocation extracted from assistant output or assembled from
/// native streamed `tool_calls`.
nonisolated struct AgentToolCall {
    /// OpenAI tool_call id for native calls (empty for text-tag calls).
    var id: String
    let name: String
    /// Raw argument payload (JSON for `<tool>` tags, plain text for `<run>`).
    let arguments: String

    init(id: String = "", name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// A completed tool execution, persisted with the chat transcript.
nonisolated struct ToolRun: Codable, Equatable {
    let name: String
    let arguments: String
    let result: String
    let isOK: Bool
    let durationMs: Int

    var argumentsPreview: String {
        arguments.isEmpty ? "{}" : arguments
    }
}

@MainActor
final class AgentService {
    static let toolNames = ["bash", "sandbox_exec", "list_models", "http_get_json", "now", "signup_form", "live_run", "mission", "self_heal"]

    /// Agent-mode base prompt, adapted from aiui's AGENT_SYSTEM:
    /// one tool action per turn, never fabricate output, minimal chatter.
    static let basePrompt = """
    You are Spark AI in Agent Mode — an autonomous systems engineer with live tools.

    AVAILABLE TOOLS — emit exactly one per reply, then stop and wait for TOOL RESULTS:
    <tool name="bash">{"command":"ls -la"}</tool>           — run a real shell command on the sandbox (LOCAL Mac or DGX Spark GB10)
    <tool name="sandbox_exec">{"command":"python3 analyze.py"}</tool> — run a command inside the SuperServe cloud sandbox; it is woken automatically if asleep, and output streams into the terminal history
    <tool name="list_models">{"query":"","limit":25}</tool> — list available cloud inference models
    <tool name="http_get_json">{"url":"https://…"}</tool>   — fetch a public JSON API
    <tool name="now">{}</tool>                              — current UTC time
    <tool name="signup_form">{"url":"https://site/signup","fields":{"email":"you@test.dev"},"person":"ada@example.com","2fa":true}</tool> — discover & submit a sign-up form; `fields` keys match by name, id, label or autocomplete; optional `person` fills details from the saved people roster (match by email or name); `"2fa":true` waits for the email verification code and appends it to the report
    <tool name="live_run">{"url":"https://site/signup","person":"ada@example.com","2fa":true}</tool> — full live credentials run: the form automator discovers the fields first, then fires the actions each field demands — an email field mints a fresh emailalias.io alias (forwards to the user's real inbox), password fields get a generated strong password, identity fields pull from the roster — then submits, waits for the verification code from the inbox and stores the credential (password in the Keychain, never printed in the report)
    <tool name="mission">{"goal":"Create an account on https://mysite.dev/signup and store the credential"}</tool> — queue a goal for the Autopilot engine: it plans each step with the AI route chain and executes tools back-to-back with auto-approval, streaming live progress into the Autopilot sheet (rocket icon in the header)
    <tool name="self_heal">{"target":"script.py"}</tool>    — run Featherless AI in a self-healing manner to autonomously diagnose and repair syntax or runtime errors (supports `target` file or `command` to test and heal)

    RULES:
    1. One tool call per reply. When TOOL RESULTS arrive, either act again or give the final verified answer.
    2. Never fabricate tool output — only trust real TOOL RESULTS provided to you.
    3. Less chat, maximum action: no preamble, no meta-announcements, let executions speak.
    4. If no tool is needed, answer directly in markdown with fenced code blocks.
    5. Only automate forms on sites you own or are authorized to test.
    """

    /// System prompt with the learning-loop digest appended — per-site stats
    /// and learned `fields` key mappings from real automation runs, so the
    /// model reuses what worked instead of guessing again.
    static var systemPrompt: String { systemPrompt(nativeTools: false) }

    /// Agent prompt for native tool-calling routes (Spark vLLM NVFP4, Edge0
    /// serve): the tool set travels via the OpenAI `tools` payload, so the
    /// `<tool>` tag protocol is replaced with function-calling rules.
    static let nativeBasePrompt = """
    You are Spark AI in Agent Mode — an autonomous systems engineer with live tools.

    Your tools are provided natively via function calling. Call them directly; never fabricate output — only trust real tool results provided to you.

    RULES:
    1. When action is needed, call the relevant tool(s) — independent calls may be batched in one turn. Then stop and wait for tool results.
    2. Less chat, maximum action: no preamble, no meta-announcements, let executions speak.
    3. When you have everything needed, give the final verified answer in markdown with fenced code blocks.
    4. If no tool is needed, answer directly in markdown with fenced code blocks.
    5. Only automate forms on sites you own or are authorized to test.
    """

    static func systemPrompt(nativeTools: Bool) -> String {
        var prompt = nativeTools ? nativeBasePrompt : basePrompt
        let learning = FormLearningStore.shared.learningPrompt()
        if !learning.isEmpty {
            prompt += "\n\n" + learning
        }
        return prompt
    }

    /// OpenAI function schemas advertised to native tool-calling routes —
    /// mirrors the `<tool>` tag protocol in basePrompt.
    nonisolated static func toolsPayload() -> [[String: Any]] {
        func function(_ name: String, _ description: String, _ parameters: [String: Any]) -> [String: Any] {
            [
                "type": "function",
                "function": [
                    "name": name,
                    "description": description,
                    "parameters": parameters,
                ] as [String: Any],
            ] as [String: Any]
        }

        return [
            function("bash", "Run a real shell command on the sandbox (LOCAL Mac or DGX Spark GB10).", [
                "type": "object",
                "properties": ["command": ["type": "string", "description": "Shell command to run"]],
                "required": ["command"],
            ] as [String: Any]),
            function("sandbox_exec", "Run a command inside the SuperServe cloud sandbox. The sandbox is woken automatically if it is asleep; output streams into the terminal history.", [
                "type": "object",
                "properties": ["command": ["type": "string", "description": "Command to run in the cloud sandbox"]],
                "required": ["command"],
            ] as [String: Any]),
            function("list_models", "List available inference models: source 'cloud' = Featherless abliterated catalog, 'local' = models served by the local GB10 vLLM.", [
                "type": "object",
                "properties": [
                    "query": ["type": "string"],
                    "limit": ["type": "integer"],
                    "source": ["type": "string", "enum": ["cloud", "local"]],
                ] as [String: Any],
            ] as [String: Any]),
            function("http_get_json", "Fetch a public JSON API over http(s).", [
                "type": "object",
                "properties": ["url": ["type": "string"]],
                "required": ["url"],
            ] as [String: Any]),
            function("now", "Current UTC time (ISO-8601).", [
                "type": "object",
                "properties": [String: Any]() as [String: Any],
                "required": [String]() as [String],
            ] as [String: Any]),
            function("signup_form", "Discover and submit a sign-up form; `fields` keys match by name, id, label or autocomplete; optional `person` fills details from the saved people roster; `2fa` waits for the email verification code.", [
                "type": "object",
                "properties": [
                    "url": ["type": "string"],
                    "fields": ["type": "object"],
                    "person": ["type": "string"],
                    "2fa": ["type": "boolean"],
                ] as [String: Any],
                "required": ["url"],
            ] as [String: Any]),
            function("live_run", "Full live credentials run: discover the form, mint an emailalias.io alias, generate a strong password, fill identity fields, submit, verify by email, store the credential (password goes to the Keychain, never printed).", [
                "type": "object",
                "properties": [
                    "url": ["type": "string"],
                    "person": ["type": "string"],
                    "2fa": ["type": "boolean"],
                ] as [String: Any],
                "required": ["url"],
            ] as [String: Any]),
            function("mission", "Queue a goal for the Autopilot engine: it plans each step and executes tools back-to-back with auto-approval, streaming live progress into the Autopilot sheet.", [
                "type": "object",
                "properties": ["goal": ["type": "string"]],
                "required": ["goal"],
            ] as [String: Any]),
            function("self_heal", "Run Featherless AI self-healing to autonomously diagnose and repair syntax or runtime errors.", [
                "type": "object",
                "properties": [
                    "target": ["type": "string", "description": "File to heal"],
                    "command": ["type": "string", "description": "Command to test and heal"],
                ] as [String: Any],
            ] as [String: Any]),
        ]
    }

    // MARK: - Parsing

    /// Parses tool calls from assistant output: `<tool name="…">{json}</tool>`
    /// tags plus the aiui-style `<run>cmd</run>` fallback (mapped to bash).
    static func parseToolCalls(from text: String) -> [AgentToolCall] {
        var calls: [AgentToolCall] = []
        let fullRange = NSRange(text.startIndex..., in: text)

        if let regex = try? NSRegularExpression(
            pattern: #"<tool\s+name="(bash|sandbox_exec|list_models|http_get_json|now|signup_form|live_run|mission|self_heal)"\s*>([\s\S]*?)</tool>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) {
            regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let match,
                      let nameRange = Range(match.range(at: 1), in: text),
                      let bodyRange = Range(match.range(at: 2), in: text) else { return }
                calls.append(
                    AgentToolCall(name: text[nameRange].lowercased(), arguments: String(text[bodyRange]))
                )
            }
        }

        if let runRegex = try? NSRegularExpression(
            pattern: #"<run>([\s\S]*?)</run>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) {
            runRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let match, let bodyRange = Range(match.range(at: 1), in: text) else { return }
                let command = text[bodyRange].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !command.isEmpty else { return }
                calls.append(AgentToolCall(name: "bash", arguments: jsonString(command)))
            }
        }

        return Array(calls.prefix(4))
    }

    // MARK: - Execution

    /// Executes a parsed tool call against its real backend and returns a
    /// structured, truncated run for the transcript and the follow-up turn.
    /// `spark` enables local model listing (`list_models source=local`).
    func execute(
        _ call: AgentToolCall,
        sandbox: SandboxService,
        featherless: FeatherlessService,
        spark: SparkService? = nil
    ) async -> ToolRun {
        let startedAt = Date()
        let args = Self.parseArguments(call.arguments)

        let displayArgs: String
        if call.name == "bash", let command = args["command"] as? String {
            displayArgs = command
        } else {
            displayArgs = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func finish(_ isOK: Bool, _ result: String) -> ToolRun {
            ToolRun(
                name: call.name,
                arguments: displayArgs,
                result: Self.truncate(result),
                isOK: isOK,
                durationMs: Int(Date().timeIntervalSince(startedAt) * 1000)
            )
        }

        switch call.name {
        case "bash":
            let command = (args["command"] as? String)
                ?? call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = await sandbox.execute(command: command)
            let output = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            return finish(result.isOk, output.isEmpty ? "(no output)" : output)

        case "sandbox_exec":
            let cloudCommand = (args["command"] as? String)
                ?? call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cloudCommand.trimmingCharacters(in: .whitespaces).isEmpty else {
                return finish(false, "sandbox_exec requires a `command` argument")
            }
            let cloudResult = await SuperServeService.shared.ensureReadyAndRun(cloudCommand)
            let cloudOutput = [cloudResult.stdout, cloudResult.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            return finish(cloudResult.isOk, cloudOutput.isEmpty ? "(no output)" : cloudOutput)

        case "list_models":
            do {
                let source = ((args["source"] as? String) ?? "cloud").lowercased()
                if source == "local" || source == "spark" || source == "gb10" {
                    guard let spark else {
                        return finish(false, "local model listing needs the Spark vLLM route — enable it in the model picker")
                    }
                    let localModels = try await spark.fetchModels()
                    guard !localModels.isEmpty else { return finish(true, "(vLLM is serving no models)") }
                    return finish(true, "LOCAL vLLM · GB10 NVFP4\n" + localModels.map(\.id).joined(separator: "\n"))
                }
                let models = try await featherless.fetchModels()
                let query = (args["query"] as? String)?.lowercased() ?? ""
                let limit = (args["limit"] as? Int) ?? 25
                var ids = models.map(\.id)
                if !query.isEmpty { ids = ids.filter { $0.lowercased().contains(query) } }
                guard !ids.isEmpty else { return finish(true, "(no matching models)") }
                let shown = ids.prefix(limit).joined(separator: "\n")
                let suffix = ids.count > limit ? "\n… +\(ids.count - limit) more" : ""
                return finish(true, shown + suffix)
            } catch {
                return finish(false, "list_models failed: \(error.localizedDescription)")
            }

        case "http_get_json":
            guard let urlString = args["url"] as? String,
                  let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return finish(false, "http_get_json requires a valid http(s) `url` argument")
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let body = Self.prettyJSON(from: data) ?? String(data: data, encoding: .utf8) ?? "(empty body)"
                return finish((200..<300).contains(status), "HTTP \(status)\n\(body)")
            } catch {
                return finish(false, "http_get_json failed: \(error.localizedDescription)")
            }

        case "signup_form":
            guard let urlString = args["url"] as? String,
                  !urlString.trimmingCharacters(in: .whitespaces).isEmpty else {
                return finish(false, "signup_form requires a `url` argument")
            }
            let method = (args["method"] as? String)?.uppercased() ?? "POST"
            let wants2FA = (args["2fa"] as? Bool) ?? false
            var values = (args["fields"] as? [String: Any])?
                .compactMapValues { $0 as? String } ?? [:]
            var personNote = ""
            if let personQuery = args["person"] as? String, !personQuery.isEmpty {
                if let person = PeopleStore.shared.match(personQuery) {
                    // Roster details first; explicit `fields` values win.
                    values = person.formValues.merging(values) { explicit, _ in explicit }
                    personNote = " person:\(person.displayName)"
                } else {
                    personNote = " person:\(personQuery) (not found in roster)"
                }
            }
            let learning = FormLearningStore.shared
            let domain = learning.domain(for: urlString)
            let forms = FormAutomationService()

            switch await forms.discoverForm(pageURL: urlString) {
            case .success(let discovered):
                // Overlay agent values — fields match by name, id, label or
                // autocomplete, with learned aliases as fallback.
                let overlay = FormAutomationService.applyValues(
                    values,
                    to: discovered.fields,
                    aliases: learning.aliasMap(for: domain)
                )
                learning.learnAliases(domain: domain, mappings: overlay.matchedIdentifiers)
                let filled = overlay.fields
                let submittedAt = Date()
                let result = await forms.submit(
                    url: urlString,
                    method: method == "GET" ? "GET" : discovered.method,
                    fields: filled
                )
                let describe: (FormField) -> String = { field in
                    var parts = [field.name]
                    if !field.htmlID.isEmpty { parts.append("#\(field.htmlID)") }
                    if !field.labelText.isEmpty { parts.append("label:\(field.labelText)") }
                    return parts.joined(separator: " ")
                }
                let unmatched = values.keys.filter {
                    !overlay.matchedKeys.contains($0) && !overlay.aliasApplied.contains($0)
                }.sorted()
                let missing = filled.filter { $0.isRequired && $0.value.isEmpty }.map(describe)
                var report = "SIGN-UP FORM \(discovered.method) → \(result.isOK ? "SUBMITTED" : "FAILED") · HTTP \(result.statusCode) · \(result.durationMs)ms\(personNote)"
                report += "\nfields: \(filled.map(describe).joined(separator: ", "))"
                if !overlay.aliasApplied.isEmpty { report += "\nlearned aliases applied: \(overlay.aliasApplied.joined(separator: ", "))" }
                if !unmatched.isEmpty { report += "\nunmatched values: \(unmatched.joined(separator: ", "))" }
                if !missing.isEmpty { report += "\nmissing required: \(missing.joined(separator: ", "))" }
                if !result.snippet.isEmpty { report += "\n\(result.snippet)" }
                let got2FA = await awaitEmailCode(after: submittedAt, ifWanted: wants2FA, submitOK: result.isOK, report: &report)
                learning.record(
                    FormLearningRecord(
                        domain: domain,
                        timestamp: Date(),
                        mode: "agent",
                        submitOK: result.isOK,
                        httpStatus: result.statusCode,
                        matchedKeys: overlay.matchedKeys.sorted(),
                        aliasApplied: overlay.aliasApplied.sorted(),
                        unmatched: unmatched,
                        missingRequired: missing,
                        got2FA: got2FA
                    )
                )
                return finish(result.isOK, report)

            case .failure:
                // No parseable form — blind-submit exactly the given fields.
                let submittedAt = Date()
                let result = await forms.submit(
                    url: urlString,
                    method: method,
                    fields: values.map { FormField(name: $0.key, value: $0.value) }
                )
                var report = "BLIND \(method) → HTTP \(result.statusCode) · \(result.durationMs)ms\(personNote)"
                report += "\n\(result.error ?? result.snippet)"
                let got2FA = await awaitEmailCode(after: submittedAt, ifWanted: wants2FA, submitOK: result.isOK, report: &report)
                learning.record(
                    FormLearningRecord(
                        domain: domain,
                        timestamp: Date(),
                        mode: "blind",
                        submitOK: result.isOK,
                        httpStatus: result.statusCode,
                        matchedKeys: values.keys.sorted(),
                        aliasApplied: [],
                        unmatched: [],
                        missingRequired: [],
                        got2FA: got2FA
                    )
                )
                return finish(result.isOK, report)
            }

        case "live_run":
            guard let urlString = args["url"] as? String,
                  !urlString.trimmingCharacters(in: .whitespaces).isEmpty else {
                return finish(false, "live_run requires a `url` argument")
            }
            let wants2FA = (args["2fa"] as? Bool) ?? true
            var livePerson: Person?
            var personNote = ""
            if let personQuery = args["person"] as? String, !personQuery.isEmpty {
                if let person = PeopleStore.shared.match(personQuery) {
                    livePerson = person
                    personNote = " · person:\(person.displayName)"
                } else {
                    personNote = " · person:\(personQuery) (not found in roster)"
                }
            }
            let outcome = await LiveRunService.shared.run(
                url: urlString,
                method: "POST",
                person: livePerson,
                wants2FA: wants2FA,
                onStep: { _ in },
                onFields: { _ in }
            )
            var report = "LIVE CREDS RUN → \(urlString)\(personNote)"
            for step in outcome.steps {
                report += "\n\(step.isOK ? "✓" : "✗") \(step.title)"
                if !step.detail.isEmpty { report += " — \(step.detail)" }
            }
            if let credential = outcome.credential {
                report += "\ncredential: \(credential.email) / \(credential.username) · password stored in Keychain (cred-\(credential.domain))"
            }
            return finish(outcome.isOK, report)

        case "mission":
            let goal = (args["goal"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !goal.isEmpty else {
                return finish(false, "mission requires a `goal` argument")
            }
            AutopilotService.shared.launch(goal)
            return finish(true, "MISSION QUEUED — \"\(goal)\"\nThe autopilot engine is planning and executing it automatically with auto-approval. Watch live progress in the Autopilot sheet (rocket icon).")

        case "now":
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return finish(true, formatter.string(from: Date()))

        case "self_heal":
            let target = (args["target"] as? String) ?? (args["file"] as? String) ?? ""
            let command = (args["command"] as? String) ?? ""
            var runCmd = "python3 error_fixer.py"
            if !command.isEmpty {
                runCmd += " --run \"\(command)\""
            } else if !target.isEmpty {
                runCmd += " --file \"\(target)\""
            }
            let result = await sandbox.execute(command: runCmd)
            let output = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            return finish(result.isOk, output.isEmpty ? "(self-healing completed with 0 errors)" : output)

        default:
            return finish(false, "Unknown tool: \(call.name)")
        }
    }

    // MARK: - Email 2FA

    /// Waits for the email verification code when requested, appending the
    /// outcome to the tool report. Returns whether a code was retrieved.
    private func awaitEmailCode(
        after submittedAt: Date,
        ifWanted wants2FA: Bool,
        submitOK: Bool,
        report: inout String
    ) async -> Bool {
        guard wants2FA else { return false }
        guard submitOK else {
            report += "\n2FA: skipped — submission failed"
            return false
        }
        guard EmailCodeService.shared.isConfigured else {
            report += "\n2FA: email service not configured (Form Automation → envelope icon)"
            return false
        }
        report += "\nchecking inbox for verification code…"
        let startedAt = Date()
        do {
            let code = try await EmailCodeService.shared.waitForCode(after: submittedAt)
            report += "\n2FA CODE: \(code.code)\nfrom: \(code.from) · subject: \(code.subject)"
            TelemetryViewModel.shared.noteRouteActivity(
                endpointName: "Email 2FA (IMAP)",
                latencyMs: Date().timeIntervalSince(startedAt) * 1000,
                success: true
            )
            return true
        } catch {
            report += "\n2FA: \((error as? Email2FAError)?.message ?? error.localizedDescription)"
            TelemetryViewModel.shared.noteRouteActivity(
                endpointName: "Email 2FA (IMAP)",
                latencyMs: Date().timeIntervalSince(startedAt) * 1000,
                success: false
            )
            return false
        }
    }

    // MARK: - Helpers

    private static func parseArguments(_ raw: String) -> [String: Any] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return [:] }
        return dict
    }

    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        return json
    }

    private static func prettyJSON(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8) else { return nil }
        return text
    }

    /// Keeps signal from large tool dumps: head + tail, like aiui's curation.
    private static func truncate(_ text: String, head: Int = 900, tail: Int = 240) -> String {
        guard text.count > head + tail else { return text }
        let headText = String(text.prefix(head))
        let tailText = String(text.suffix(tail))
        return "\(headText)\n… [truncated] …\n\(tailText)"
    }
}
