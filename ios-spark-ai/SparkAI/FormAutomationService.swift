//
//  FormAutomationService.swift
//  SparkAI
//
//  Website sign-up form automation: fetches a page, discovers form fields
//  from raw HTML, fills them with supplied values and submits over real
//  HTTP (urlencoded). Templates persist locally. Also exposed to Agent Mode
//  as the `signup_form` tool.
//

import Foundation

/// A single form field discovered in HTML or authored by the user.
nonisolated struct FormField: Codable, Identifiable, Equatable {
    var name: String
    var type: String
    var placeholder: String
    var value: String
    var isRequired: Bool
    var options: [String]
    /// Element `id` attribute — many AI-built forms key fields by id only.
    var htmlID: String
    /// `aria-label` attribute.
    var ariaLabel: String
    /// Text of a `<label for="…">` pointing at this field.
    var labelText: String
    /// `autocomplete` hint (e.g. "email", "new-password").
    var autocomplete: String

    var id: String { !htmlID.isEmpty ? htmlID : name }

    init(
        name: String,
        type: String = "text",
        placeholder: String = "",
        value: String = "",
        isRequired: Bool = false,
        options: [String] = [],
        htmlID: String = "",
        ariaLabel: String = "",
        labelText: String = "",
        autocomplete: String = ""
    ) {
        self.name = name
        self.type = type
        self.placeholder = placeholder
        self.value = value
        self.isRequired = isRequired
        self.options = options
        self.htmlID = htmlID
        self.ariaLabel = ariaLabel
        self.labelText = labelText
        self.autocomplete = autocomplete
    }

    /// Tolerates templates saved before identifier fields existed.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "text"
        placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder) ?? ""
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        isRequired = try container.decodeIfPresent(Bool.self, forKey: .isRequired) ?? false
        options = try container.decodeIfPresent([String].self, forKey: .options) ?? []
        htmlID = try container.decodeIfPresent(String.self, forKey: .htmlID) ?? ""
        ariaLabel = try container.decodeIfPresent(String.self, forKey: .ariaLabel) ?? ""
        labelText = try container.decodeIfPresent(String.self, forKey: .labelText) ?? ""
        autocomplete = try container.decodeIfPresent(String.self, forKey: .autocomplete) ?? ""
    }
}

/// A form template remembered across launches.
nonisolated struct FormSpec: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var url: String
    var method: String
    var fields: [FormField]
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        url: String,
        method: String,
        fields: [FormField],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.method = method
        self.fields = fields
        self.createdAt = createdAt
    }
}

/// The first form found in a page, before user values are applied.
nonisolated struct DiscoveredForm: Equatable {
    var action: String
    var method: String
    var fields: [FormField]
}

/// Discovery outcome — a dedicated enum because `String` is not `Error`
/// and can't serve as a `Result` failure type.
nonisolated enum FormDiscoveryOutcome {
    case success(DiscoveredForm)
    case failure(String)
}

/// Outcome of a real form submission.
nonisolated struct FormSubmitResult: Equatable {
    var isOK: Bool
    var statusCode: Int
    var finalURL: String
    var durationMs: Int
    var snippet: String
    var error: String?
}

nonisolated final class FormAutomationService {
    private static let presetsKey = "form-automation-presets"
    private static let maxFields = 30
    /// Input types that never carry submittable user data.
    private static let skippedTypes: Set<String> = ["submit", "button", "image", "file", "reset"]

    // MARK: - Templates

    func loadPresets() -> [FormSpec] {
        PersistenceStore.load([FormSpec].self, forKey: Self.presetsKey) ?? []
    }

    func savePreset(_ spec: FormSpec) {
        var presets = loadPresets()
        presets.removeAll { $0.url == spec.url && $0.name == spec.name }
        presets.insert(spec, at: 0)
        PersistenceStore.save(Array(presets.prefix(12)), forKey: Self.presetsKey)
    }

    func deletePreset(_ id: UUID) {
        var presets = loadPresets()
        presets.removeAll { $0.id == id }
        PersistenceStore.save(presets, forKey: Self.presetsKey)
    }

    // MARK: - Discovery

    /// Fetches the page and extracts the first form's fields.
    func discoverForm(pageURL: String) async -> FormDiscoveryOutcome {
        guard let url = Self.normalizedURL(pageURL) else {
            return .failure("Invalid URL")
        }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<400).contains(status) else { return .failure("HTTP \(status)") }
            guard let html = String(data: data, encoding: .utf8) else {
                return .failure("Unsupported page encoding")
            }
            let form = Self.parseForm(html: html, baseURL: url)
            guard !form.fields.isEmpty else { return .failure("No form fields found") }
            return .success(form)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// Regex extraction of action/method plus input, textarea and select
    /// fields, capturing every identifier: name, id, aria-label, label text
    /// and autocomplete. Fields without name or id are skipped (browsers
    /// wouldn't submit them either).
    static func parseForm(html: String, baseURL: URL) -> DiscoveredForm {
        var action = ""
        var method = "POST"
        var scope = html

        if let openRange = html.range(of: #"<form\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
            let openTag = String(html[openRange])
            action = firstCapture(#"action\s*=\s*["']([^"']*)["']"#, in: openTag) ?? ""
            let found = firstCapture(#"method\s*=\s*["']([^"']*)["']"#, in: openTag)
            method = (found?.isEmpty == false ? found! : "POST").uppercased()
            if let closeRange = html.range(
                of: #"</form>"#,
                options: [.regularExpression, .caseInsensitive],
                range: openRange.upperBound..<html.endIndex
            ) {
                scope = String(html[openRange.upperBound..<closeRange.lowerBound])
            }
        }

        let labels = Self.labelTargets(in: scope)
        var fields: [FormField] = []

        for tag in allMatches(#"<input\b[^>]*>"#, in: scope) {
            let htmlID = firstCapture(#"\bid\s*=\s*["']([^"']+)["']"#, in: tag) ?? ""
            let name = firstCapture(#"name\s*=\s*["']([^"']+)["']"#, in: tag) ?? htmlID
            guard !name.isEmpty else { continue }
            let type = (firstCapture(#"type\s*=\s*["']([^"']*)["']"#, in: tag) ?? "text").lowercased()
            guard !skippedTypes.contains(type) else { continue }
            fields.append(
                FormField(
                    name: name,
                    type: type,
                    placeholder: firstCapture(#"placeholder\s*=\s*["']([^"']*)["']"#, in: tag) ?? "",
                    value: firstCapture(#"value\s*=\s*["']([^"']*)["']"#, in: tag) ?? "",
                    isRequired: tag.range(of: #"\brequired\b"#, options: [.regularExpression, .caseInsensitive]) != nil,
                    htmlID: htmlID,
                    ariaLabel: firstCapture(#"aria-label\s*=\s*["']([^"']*)["']"#, in: tag) ?? "",
                    labelText: labels[htmlID] ?? "",
                    autocomplete: firstCapture(#"autocomplete\s*=\s*["']([^"']*)["']"#, in: tag) ?? ""
                )
            )
        }

        for block in allMatches(#"<textarea\b[^>]*>[\s\S]*?</textarea>"#, in: scope) {
            guard let openTag = allMatches(#"<textarea\b[^>]*>"#, in: block).first else { continue }
            let htmlID = firstCapture(#"\bid\s*=\s*["']([^"']+)["']"#, in: openTag) ?? ""
            let name = firstCapture(#"name\s*=\s*["']([^"']+)["']"#, in: openTag) ?? htmlID
            guard !name.isEmpty else { continue }
            fields.append(
                FormField(
                    name: name,
                    type: "textarea",
                    placeholder: firstCapture(#"placeholder\s*=\s*["']([^"']*)["']"#, in: openTag) ?? "",
                    isRequired: block.range(of: #"\brequired\b"#, options: [.regularExpression, .caseInsensitive]) != nil,
                    htmlID: htmlID,
                    ariaLabel: firstCapture(#"aria-label\s*=\s*["']([^"']*)["']"#, in: openTag) ?? "",
                    labelText: labels[htmlID] ?? "",
                    autocomplete: firstCapture(#"autocomplete\s*=\s*["']([^"']*)["']"#, in: openTag) ?? ""
                )
            )
        }

        for block in allMatches(#"<select\b[^>]*>[\s\S]*?</select>"#, in: scope) {
            guard let openTag = allMatches(#"<select\b[^>]*>"#, in: block).first else { continue }
            let htmlID = firstCapture(#"\bid\s*=\s*["']([^"']+)["']"#, in: openTag) ?? ""
            let name = firstCapture(#"name\s*=\s*["']([^"']+)["']"#, in: openTag) ?? htmlID
            guard !name.isEmpty else { continue }
            let options = allMatches(#"<option\b[^>]*>"#, in: block)
                .compactMap { firstCapture(#"value\s*=\s*["']([^"']*)["']"#, in: $0) }
            fields.append(
                FormField(
                    name: name,
                    type: "select",
                    isRequired: block.range(of: #"\brequired\b"#, options: [.regularExpression, .caseInsensitive]) != nil,
                    options: Array(options.prefix(30)),
                    htmlID: htmlID,
                    ariaLabel: firstCapture(#"aria-label\s*=\s*["']([^"']*)["']"#, in: openTag) ?? "",
                    labelText: labels[htmlID] ?? "",
                    autocomplete: firstCapture(#"autocomplete\s*=\s*["']([^"']*)["']"#, in: openTag) ?? ""
                )
            )
        }

        return DiscoveredForm(
            action: action,
            method: method,
            fields: Array(fields.prefix(maxFields))
        )
    }

    /// Maps `for="…"` targets to their human-readable label text.
    private static func labelTargets(in scope: String) -> [String: String] {
        var targets: [String: String] = [:]
        for block in allMatches(#"<label\b[^>]*>[\s\S]*?</label>"#, in: scope) {
            guard let target = firstCapture(#"for\s*=\s*["']([^"']+)["']"#, in: block) else { continue }
            let text = stripTags(block)
                .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { targets[target] = String(text.prefix(60)) }
        }
        return targets
    }

    // MARK: - Value Matching

    /// Every lowercase key a field can be addressed by.
    static func identifierKeys(for field: FormField) -> [String] {
        [field.name, field.htmlID, field.ariaLabel, field.labelText, field.autocomplete, field.placeholder]
            .filter { !$0.isEmpty }
            .map { $0.lowercased() }
    }

    /// Overlays supplied values onto discovered fields. Each field matches
    /// case-insensitively against any identifier — name, HTML id, aria-label,
    /// label text, autocomplete hint or placeholder — however the form names
    /// it. `aliases` supplies learned caller-key → identifier mappings from
    /// prior runs on the same site, used when direct matching misses.
    /// Returns the filled fields, the caller keys that landed directly, the
    /// identifier each caller key landed on, and keys filled via aliases.
    static func applyValues(
        _ values: [String: String],
        to fields: [FormField],
        aliases: [String: String] = [:]
    ) -> (fields: [FormField], matchedKeys: Set<String>, matchedIdentifiers: [String: String], aliasApplied: [String]) {
        let lookup = Dictionary(uniqueKeysWithValues: values.map { ($0.key.lowercased(), $0.value) })
        // Invert learned aliases: identifier → caller key.
        let aliasByIdentifier = Dictionary(
            aliases.map { ($0.value.lowercased(), $0.key.lowercased()) },
            uniquingKeysWith: { first, _ in first }
        )
        var updated = fields
        var matchedKeys: Set<String> = []
        var matchedIdentifiers: [String: String] = [:]
        var aliasApplied: [String] = []
        var usedCallerKeys: Set<String> = []

        func originalKey(for lowercased: String) -> String? {
            values.first(where: { $0.key.lowercased() == lowercased })?.key
        }

        for index in updated.indices {
            let field = updated[index]
            let candidates = identifierKeys(for: field)
            if let key = candidates.first(where: { lookup[$0] != nil }),
               let value = lookup[key] {
                updated[index].value = value
                if let original = originalKey(for: key) {
                    matchedKeys.insert(original)
                    matchedIdentifiers[original] = key
                    usedCallerKeys.insert(key)
                }
            } else if updated[index].value.isEmpty,
                      let callerKey = candidates.compactMap({ aliasByIdentifier[$0] }).first,
                      !usedCallerKeys.contains(callerKey),
                      let value = lookup[callerKey] {
                // Learned fallback: this identifier caught the same caller
                // key on a previous run of this site.
                updated[index].value = value
                if let original = originalKey(for: callerKey) {
                    aliasApplied.append(original)
                    matchedIdentifiers[original] = candidates.first { aliasByIdentifier[$0] != nil } ?? callerKey
                    usedCallerKeys.insert(callerKey)
                }
            }
        }
        return (updated, matchedKeys, matchedIdentifiers, aliasApplied)
    }

    // MARK: - Submission

    /// Submits the fields as a urlencoded GET query or POST body and reports
    /// the real HTTP outcome with a stripped-text response snippet.
    func submit(url: String, method: String, fields: [FormField]) async -> FormSubmitResult {
        let startedAt = Date()
        let duration: () -> Int = { Int(Date().timeIntervalSince(startedAt) * 1000) }

        guard let base = Self.normalizedURL(url) else {
            return FormSubmitResult(
                isOK: false, statusCode: -1, finalURL: url,
                durationMs: 0, snippet: "", error: "Invalid URL"
            )
        }

        let pairs = fields
            .filter { !$0.name.isEmpty }
            .map { URLQueryItem(name: $0.name, value: $0.value) }

        var request: URLRequest
        if method.uppercased() == "GET" {
            guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
                return FormSubmitResult(
                    isOK: false, statusCode: -1, finalURL: base.absoluteString,
                    durationMs: duration(), snippet: "", error: "Invalid URL"
                )
            }
            components.queryItems = pairs
            guard let target = components.url else {
                return FormSubmitResult(
                    isOK: false, statusCode: -1, finalURL: base.absoluteString,
                    durationMs: duration(), snippet: "", error: "Invalid query"
                )
            }
            request = URLRequest(url: target)
            request.httpMethod = "GET"
        } else {
            request = URLRequest(url: base)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.encodedBody(pairs).data(using: .utf8)
        }

        request.timeoutInterval = 20
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
            forHTTPHeaderField: "User-Agent"
        )

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? -1
            let finalURL = http?.url?.absoluteString ?? base.absoluteString
            let body = String(data: data, encoding: .utf8) ?? "(binary body)"
            let ok = (200..<400).contains(status)
            return FormSubmitResult(
                isOK: ok,
                statusCode: status,
                finalURL: finalURL,
                durationMs: duration(),
                snippet: Self.truncate(Self.stripTags(body)),
                error: ok ? nil : "HTTP \(status)"
            )
        } catch {
            return FormSubmitResult(
                isOK: false,
                statusCode: -1,
                finalURL: base.absoluteString,
                durationMs: duration(),
                snippet: "",
                error: error.localizedDescription
            )
        }
    }

    // MARK: - Helpers

    static func normalizedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    /// Form-encodes pairs the way browsers do (spaces become `+`).
    private static func encodedBody(_ items: [URLQueryItem]) -> String {
        var components = URLComponents()
        components.queryItems = items.isEmpty ? [URLQueryItem(name: "_spark", value: "1")] : items
        return components.percentEncodedQuery ?? ""
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let full = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: full),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return text[range]
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    private static func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }
        let full = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: full)
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    /// Strips script/style blocks and HTML tags, collapsing whitespace —
    /// shared with the page scanner for visible-text extraction.
    static func stripTags(_ html: String) -> String {
        var text = html.replacingOccurrences(
            of: #"<(script|style)\b[\s\S]*?</\1>"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Head + tail curation so huge success pages stay readable.
    private static func truncate(_ text: String, head: Int = 700, tail: Int = 200) -> String {
        guard text.count > head + tail else { return text }
        return "\(text.prefix(head))\n… [truncated] …\n\(text.suffix(tail))"
    }
}
