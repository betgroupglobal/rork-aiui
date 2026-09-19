//
//  EmailCodeService.swift
//  SparkAI
//
//  Automatic retrieval of sign-up verification (2FA) codes from the user's
//  own mailbox over IMAP/TLS. Credentials: email address + app password,
//  with the password stored only in the Keychain. A minimal IMAP client
//  (LOGIN → SELECT → SEARCH → FETCH) speaks to the user-defined server
//  directly — nothing is routed through any cloud service.
//

import Foundation
import Network
import Observation

/// User-editable mailbox connection settings (persisted JSON; the app
/// password lives separately in the Keychain).
nonisolated struct Email2FASettings: Codable, Equatable {
    var emailAddress: String
    var imapHost: String
    var imapPort: Int
    /// Optional comma-separated sender substrings to restrict which messages count.
    var senderFilter: String
    /// Subject/body keywords identifying verification mail. Empty → defaults.
    var keywords: [String]

    init(
        emailAddress: String = "",
        imapHost: String = "",
        imapPort: Int = 993,
        senderFilter: String = "",
        keywords: [String] = []
    ) {
        self.emailAddress = emailAddress
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.senderFilter = senderFilter
        self.keywords = keywords
    }

    /// Tolerates settings saved before newer fields existed.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        emailAddress = try container.decodeIfPresent(String.self, forKey: .emailAddress) ?? ""
        imapHost = try container.decodeIfPresent(String.self, forKey: .imapHost) ?? ""
        imapPort = try container.decodeIfPresent(Int.self, forKey: .imapPort) ?? 993
        senderFilter = try container.decodeIfPresent(String.self, forKey: .senderFilter) ?? ""
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
    }
}

/// A verification code pulled out of the inbox.
nonisolated struct VerificationCode: Equatable, Sendable {
    let code: String
    let subject: String
    let from: String
}

nonisolated enum Email2FAError: Error, Equatable {
    case notConfigured
    case authFailed
    case timeout
    case codeNotFound
    case connectionFailed(String)
    case commandFailed(String)

    var message: String {
        switch self {
        case .notConfigured: return "Email service not configured"
        case .authFailed: return "Login rejected — check the address and app password"
        case .timeout: return "Mail server timed out"
        case .codeNotFound: return "No verification code found yet"
        case .connectionFailed(let detail): return "Connection failed: \(detail)"
        case .commandFailed(let detail): return "IMAP error: \(detail)"
        }
    }
}

/// Minimal IMAP client: connect (TLS), LOGIN, SELECT INBOX, SEARCH SINCE,
/// FETCH (INTERNALDATE BODY.PEEK[]). Tagged-completion driven reads; IMAP
/// literals are extracted by their declared byte count.
@MainActor
final class IMAPClient {
    struct RawMessage: Sendable {
        var internalDate: Date?
        var from: String
        var subject: String
        var bodyText: String
    }

    private var connection: NWConnection?
    private var buffer = Data()
    private var pendingData: CheckedContinuation<Data, Error>?
    private var pendingReady: CheckedContinuation<Void, Error>?

    deinit {
        connection?.cancel()
    }

    /// Logs in and counts messages since a day — used by "test connection".
    func probe(host: String, port: UInt16, user: String, password: String, sinceDay: String) async throws -> Int {
        try await connect(host: host, port: port)
        defer { disconnect() }
        try await tagged("A1", "LOGIN \(Self.quoted(user)) \(Self.quoted(password))", isAuth: true)
        try await tagged("A2", "SELECT \"INBOX\"")
        let search = try await tagged("A3", "SEARCH SINCE \(sinceDay)")
        return Self.sequenceNumbers(from: search).count
    }

    /// Fetches up to `limit` messages received on/after the given day,
    /// decoded to (from, subject, plain text).
    func fetchMessages(
        host: String,
        port: UInt16,
        user: String,
        password: String,
        sinceDay: String,
        sinceDate: Date,
        limit: Int
    ) async throws -> [RawMessage] {
        try await connect(host: host, port: port)
        defer { disconnect() }
        try await tagged("A1", "LOGIN \(Self.quoted(user)) \(Self.quoted(password))", isAuth: true)
        try await tagged("A2", "SELECT \"INBOX\"")
        let search = try await tagged("A3", "SEARCH SINCE \(sinceDay)")
        let numbers = Self.sequenceNumbers(from: search).suffix(limit)
        var messages: [RawMessage] = []
        for (offset, number) in numbers.enumerated() {
            let reply = try await fetchOne(tag: "F\(offset)", sequence: number)
            guard var message = Self.parseMessage(from: reply) else { continue }
            // Day-granular SEARCH can include older mail — drop it here.
            if let date = message.internalDate, date < sinceDate.addingTimeInterval(-120) { continue }
            message.bodyText = Self.normalize(Self.decodeBody(message.bodyText))
            messages.append(message)
        }
        _ = try? await tagged("A9", "LOGOUT")
        return messages
    }

    /// Force-cancels an in-flight session (timeout path).
    func abort() {
        failPending(with: Email2FAError.timeout)
        connection?.cancel()
        connection = nil
    }

    func invalidate() {
        disconnect()
    }

    // MARK: - Session plumbing

    private func connect(host: String, port: UInt16) async throws {
        let params = NWParameters.tls
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 993,
            using: params
        )
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handleState(state) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingReady = continuation
            connection.start(queue: DispatchQueue(label: "spark.imap", qos: .userInitiated))
        }
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            pendingReady?.resume()
            pendingReady = nil
        case .failed(let error):
            let failure = Email2FAError.connectionFailed(error.localizedDescription)
            pendingReady?.resume(throwing: failure)
            pendingReady = nil
        case .cancelled:
            let failure = Email2FAError.connectionFailed("cancelled")
            pendingReady?.resume(throwing: failure)
            pendingReady = nil
        default:
            break
        }
    }

    private func disconnect() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        buffer.removeAll()
    }

    private func failPending(with error: Error) {
        pendingReady?.resume(throwing: error)
        pendingReady = nil
        pendingData?.resume(throwing: error)
        pendingData = nil
    }

    private func send(_ line: String) throws {
        guard let connection else { throw Email2FAError.connectionFailed("closed") }
        connection.send(content: Data(line.utf8), completion: .contentProcessed { _ in })
    }

    /// Sends a command and reads until its tagged completion line arrives.
    private func tagged(_ tag: String, _ command: String, isAuth: Bool = false) async throws -> Data {
        buffer.removeAll()
        try send("\(tag) \(command)\r\n")
        while !Self.hasTaggedCompletion(tag, in: buffer) {
            try await readChunk()
        }
        if let failureLine = Self.taggedFailureLine(tag, in: buffer) {
            throw isAuth ? Email2FAError.authFailed : Email2FAError.commandFailed(failureLine)
        }
        return buffer
    }

    private func fetchOne(tag: String, sequence: Int) async throws -> Data {
        try await tagged(tag, "FETCH \(sequence) (INTERNALDATE BODY.PEEK[])")
    }

    private func readChunk() async throws {
        guard let connection else { throw Email2FAError.connectionFailed("closed") }
        let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            pendingData = continuation
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
                Task { @MainActor in self.finishReceive(data: data, isComplete: isComplete, error: error) }
            }
        }
        buffer.append(data)
    }

    private func finishReceive(data: Data?, isComplete: Bool, error: NWError?) {
        guard let continuation = pendingData else { return }
        pendingData = nil
        if let data, !data.isEmpty {
            continuation.resume(returning: data)
        } else {
            connection = nil
            continuation.resume(throwing: Email2FAError.connectionFailed(error?.localizedDescription ?? "connection closed"))
        }
        _ = isComplete
    }

    // MARK: - Response parsing

    private static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }

    private static func hasTaggedCompletion(_ tag: String, in data: Data) -> Bool {
        String(decoding: data, as: UTF8.self).range(of: "(?m)^\(tag) (?:OK|NO|BAD)", options: .regularExpression) != nil
    }

    private static func taggedFailureLine(_ tag: String, in data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        guard let range = text.range(of: "(?m)^\(tag) (?:NO|BAD)[^\r\n]*", options: .regularExpression) else { return nil }
        return String(text[range])
    }

    private static func sequenceNumbers(from data: Data) -> [Int] {
        let text = String(decoding: data, as: UTF8.self)
        guard let range = text.range(of: #"(?m)^\* SEARCH ([0-9 \t]+)"#, options: .regularExpression) else { return [] }
        return String(text[range])
            .dropFirst("* SEARCH".count)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .compactMap { Int($0) }
    }

    /// Extracts the `{N}\r\n…N bytes…` IMAP literal from a FETCH reply.
    nonisolated static func literalPayload(in data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard let open = bytes.firstIndex(of: UInt8(ascii: "{")) else { return nil }
        var index = bytes.index(after: open)
        var digits = ""
        while index < bytes.endIndex, bytes[index] >= 48, bytes[index] <= 57 {
            digits.append(Character(UnicodeScalar(bytes[index])))
            index = bytes.index(after: index)
        }
        guard !digits.isEmpty,
              index < bytes.endIndex, bytes[index] == 13,
              bytes.index(after: index) < bytes.endIndex, bytes[bytes.index(after: index)] == 10,
              let count = Int(digits) else { return nil }
        let start = bytes.index(index, offsetBy: 2)
        let end = min(bytes.index(start, offsetBy: count), bytes.endIndex)
        guard start <= end else { return nil }
        return Data(bytes[start..<end])
    }

    /// Builds a decoded RawMessage from a full FETCH reply.
    nonisolated static func parseMessage(from reply: Data) -> RawMessage? {
        guard let payload = literalPayload(in: reply) else { return nil }
        let raw = String(decoding: payload, as: UTF8.self)

        var internalDate: Date?
        let replyText = String(decoding: reply, as: UTF8.self)
        if let text = firstCapture(#"INTERNALDATE "([^"]+)""#, in: replyText) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "d-LLL-yyyy HH:mm:ss ZZZ"
            internalDate = formatter.date(from: text)
        }

        let headerSplit = raw.range(of: "\r\n\r\n") ?? raw.range(of: "\n\n")
        let headers = headerSplit.map { String(raw[..<$0.lowerBound]) } ?? raw
        let body = headerSplit.map { String(raw[$0.upperBound...]) } ?? ""

        return RawMessage(
            internalDate: internalDate,
            from: Self.header("From", in: headers),
            subject: Self.header("Subject", in: headers),
            bodyText: body
        )
    }

    /// Header value with folded continuation lines unfolded.
    nonisolated private static func header(_ name: String, in headers: String) -> String {
        var value = ""
        let prefix = name.lowercased() + ":"
        for line in headers.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix(prefix) {
                value = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            } else if !value.isEmpty, line.hasPrefix(" ") || line.hasPrefix("\t") {
                value += " " + trimmed
            } else if !value.isEmpty {
                break
            }
        }
        return value
    }

    // MARK: - MIME decoding

    /// Decodes a message body: multipart selection, base64 / quoted-printable
    /// transfer encodings, then HTML → visible text.
    nonisolated static func decodeBody(_ raw: String) -> String {
        let headerSplit = raw.range(of: "\r\n\r\n") ?? raw.range(of: "\n\n")
        let headers = headerSplit.map { String(raw[..<$0.lowerBound]) } ?? ""
        let body = headerSplit.map { String(raw[$0.upperBound...]) } ?? raw
        let headerBlock = headers.lowercased()

        if let boundary = firstCapture(#"boundary\s*=\s*"([^"]+)""#, in: headers)
            ?? firstCapture(#"boundary=([^;\s]+)"#, in: headers) {
            return decodeMultipart(body, boundary: boundary)
        }
        if headerBlock.contains("base64") {
            let cleaned = body.components(separatedBy: .whitespacesAndNewlines).joined()
            if let data = Data(base64Encoded: cleaned) {
                return String(decoding: data, as: UTF8.self)
            }
            return cleaned
        }
        if headerBlock.contains("quoted-printable") {
            return decodeQuotedPrintable(body)
        }
        return body
    }

    nonisolated private static func decodeMultipart(_ body: String, boundary: String) -> String {
        var plain: String?
        var html: String?
        for part in body.components(separatedBy: "--" + boundary).dropFirst() {
            guard let split = part.range(of: "\r\n\r\n") ?? part.range(of: "\n\n") else { continue }
            let partHeaders = String(part[..<split.lowerBound]).lowercased()
            let content = String(part[split.upperBound...])
            guard partHeaders.contains("text/") else { continue }
            var decoded: String
            if partHeaders.contains("base64") {
                let cleaned = content.components(separatedBy: .whitespacesAndNewlines).joined()
                decoded = Data(base64Encoded: cleaned).map { String(decoding: $0, as: UTF8.self) } ?? cleaned
            } else if partHeaders.contains("quoted-printable") {
                decoded = decodeQuotedPrintable(content)
            } else {
                decoded = content
            }
            if partHeaders.contains("text/html") {
                html = decoded
            } else if plain == nil {
                plain = decoded
            }
        }
        if let plain { return plain }
        if let html { return FormAutomationService.stripTags(html) }
        return body
    }

    nonisolated private static func decodeQuotedPrintable(_ text: String) -> String {
        let softUnwrapped = text
            .replacingOccurrences(of: "=\r\n", with: "")
            .replacingOccurrences(of: "=\n", with: "")
        let bytes = Array(softUnwrapped.utf8)
        var output: [UInt8] = []
        var index = 0
        func hexValue(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 55
            case 97...102: return byte - 87
            default: return nil
            }
        }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "="), index + 2 < bytes.count,
               let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2]) {
                output.append(high << 4 | low)
                index += 3
            } else {
                output.append(byte)
                index += 1
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    nonisolated private static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    }

    nonisolated private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let full = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: full),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

@MainActor
@Observable
final class EmailCodeService {
    static let shared = EmailCodeService()

    private(set) var settings: Email2FASettings
    private(set) var hasPassword: Bool

    static let defaultKeywords = ["verification", "verify", "code", "confirm", "otp", "2fa", "one-time", "sign in", "login"]
    private static let settingsKey = "email-2fa-settings"
    private static let passwordAccount = "imap-app-password"
    private static let pollIntervalSeconds: UInt64 = 6

    private init() {
        settings = PersistenceStore.load(Email2FASettings.self, forKey: Self.settingsKey) ?? Email2FASettings()
        hasPassword = KeychainService.password(account: Self.passwordAccount) != nil
    }

    var isConfigured: Bool {
        !settings.emailAddress.isEmpty && !settings.imapHost.isEmpty && hasPassword
    }

    var effectiveKeywords: [String] {
        settings.keywords.isEmpty ? Self.defaultKeywords : settings.keywords
    }

    func update(_ newSettings: Email2FASettings) {
        settings = newSettings
        PersistenceStore.save(settings, forKey: Self.settingsKey)
    }

    func savePassword(_ password: String) {
        KeychainService.setPassword(password, account: Self.passwordAccount)
        hasPassword = !password.isEmpty
    }

    func deletePassword() {
        KeychainService.deletePassword(account: Self.passwordAccount)
        hasPassword = false
    }

    /// Well-known IMAP hosts for common consumer providers.
    static func hostHint(forEmail email: String) -> String? {
        let domain = email.split(separator: "@").last.map(String.init)?.lowercased() ?? ""
        switch domain {
        case "gmail.com", "googlemail.com": return "imap.gmail.com"
        case "icloud.com", "me.com", "mac.com": return "imap.mail.me.com"
        case "outlook.com", "hotmail.com", "live.com", "msn.com": return "outlook.office365.com"
        case "yahoo.com": return "imap.mail.yahoo.com"
        case "zoho.com": return "imap.zoho.com"
        default: return nil
        }
    }

    /// One inbox check: fetches recent mail and extracts the first code that
    /// passes the keyword/sender filters. Throws `.codeNotFound` when the
    /// mail hasn't arrived yet — callers should poll via waitForCode.
    func fetchVerificationCode(since: Date) async throws -> VerificationCode {
        guard isConfigured,
              let password = KeychainService.password(account: Self.passwordAccount), !password.isEmpty else {
            throw Email2FAError.notConfigured
        }
        let client = IMAPClient()
        defer { client.invalidate() }
        do {
            let messages = try await runWithTimeout(seconds: 45, client: client) { [settings] in
                try await client.fetchMessages(
                    host: settings.imapHost,
                    port: UInt16(max(1, min(settings.imapPort, 65_535))),
                    user: settings.emailAddress,
                    password: password,
                    sinceDay: Self.imapDayString(since),
                    sinceDate: since,
                    limit: 8
                )
            }
            let keywords = effectiveKeywords
            for message in messages.reversed() {
                guard Self.matches(message, keywords: keywords, senderFilter: settings.senderFilter) else { continue }
                if let code = Self.extractCode(in: message.subject) ?? Self.extractCode(in: message.bodyText) {
                    return VerificationCode(
                        code: code,
                        subject: message.subject.isEmpty ? "(no subject)" : message.subject,
                        from: message.from.isEmpty ? settings.emailAddress : message.from
                    )
                }
            }
            throw Email2FAError.codeNotFound
        } catch {
            client.abort()
            throw error
        }
    }

    /// Polls the inbox until a code arrives (or the window closes).
    func waitForCode(after submittedAt: Date, timeout: TimeInterval = 90) async throws -> VerificationCode {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            do {
                return try await fetchVerificationCode(since: submittedAt)
            } catch let error as Email2FAError where error == .codeNotFound {
                guard Date() < deadline else { throw Email2FAError.codeNotFound }
                try await Task.sleep(for: .seconds(Self.pollIntervalSeconds))
            }
        }
    }

    /// Login + inbox probe for the settings sheet.
    func testConnection() async throws -> String {
        guard isConfigured,
              let password = KeychainService.password(account: Self.passwordAccount), !password.isEmpty else {
            throw Email2FAError.notConfigured
        }
        let client = IMAPClient()
        defer { client.invalidate() }
        let count = try await runWithTimeout(seconds: 30, client: client) { [settings] in
            try await client.probe(
                host: settings.imapHost,
                port: UInt16(max(1, min(settings.imapPort, 65_535))),
                user: settings.emailAddress,
                password: password,
                sinceDay: Self.imapDayString(Date().addingTimeInterval(-86_400 * 3))
            )
        }
        return "LOGIN OK · \(count) message\(count == 1 ? "" : "s") in the last 3 days"
    }

    // MARK: - Matching & extraction

    nonisolated static func matches(_ message: IMAPClient.RawMessage, keywords: [String], senderFilter: String) -> Bool {
        let filters = senderFilter
            .lowercased()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !filters.isEmpty {
            let sender = message.from.lowercased()
            guard filters.contains(where: { sender.contains($0) }) else { return false }
        }
        let haystack = (message.subject + "\n" + message.from + "\n" + String(message.bodyText.prefix(4000))).lowercased()
        return keywords.isEmpty || keywords.contains { haystack.contains($0.lowercased()) }
    }

    /// Code extraction: strict 6-digit first (subject, then body), then any
    /// 4–8 digit run, then an alphanumeric token containing a digit.
    nonisolated static func extractCode(in text: String) -> String? {
        guard !text.isEmpty else { return nil }
        if let six = firstCapture(#"(?<!\d)(\d{6})(?!\d)"#, in: text) { return six }
        if let wide = firstCapture(#"(?<!\d)(\d{4,8})(?!\d)"#, in: text) { return wide }
        if let alnum = firstMatch(#"\b(?=[A-Z0-9]{6,8}\b)(?=[A-Z0-9]*\d)[A-Z0-9]+\b"#, in: text) { return alnum }
        return nil
    }

    nonisolated static func imapDayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d-LLL-yyyy"
        return formatter.string(from: date)
    }

    // MARK: - Timeout plumbing

    private func runWithTimeout<T: Sendable>(
        seconds: TimeInterval,
        client: IMAPClient,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                await client.abort()
                throw Email2FAError.timeout
            }
            guard let result = try await group.next() else { throw Email2FAError.timeout }
            group.cancelAll()
            return result
        }
    }

    nonisolated private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let full = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: full),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    nonisolated private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let full = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: full),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range])
    }
}
