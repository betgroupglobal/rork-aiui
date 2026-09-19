//
//  SSHPasswordService.swift
//  SparkAI
//
//  SSH credential store for the flak3dd infrastructure. Connection settings
//  (host, port, username) are persisted via PersistenceStore; the SSH
//  password lives exclusively in the Keychain under "ssh-flak3dd".
//
//  The service validates connectivity by making a lightweight TCP probe
//  to the configured host/port — a full SSH handshake would require a
//  third-party library, so the probe just confirms the port is open and
//  an SSH banner is returned.
//

import Foundation
import Observation

/// User-editable SSH connection settings (persisted JSON; the password
/// is stored separately in the Keychain and never appears here).
nonisolated struct SSHPasswordSettings: Codable, Equatable {
    var host: String = "spark-mirror.flak3dd.dev"
    var port: Int = 22
    var username: String = "root"
    /// Optional label for display in the assistants row.
    var label: String = "flak3dd"
    /// Whether SSH credential injection is enabled for live runs.
    var isEnabled: Bool = false

    /// Tolerates settings saved before newer fields existed.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = (try? container.decode(String.self, forKey: .host)) ?? "spark-mirror.flak3dd.dev"
        port = (try? container.decode(Int.self, forKey: .port)) ?? 22
        username = (try? container.decode(String.self, forKey: .username)) ?? "root"
        label = (try? container.decode(String.self, forKey: .label)) ?? "flak3dd"
        isEnabled = (try? container.decode(Bool.self, forKey: .isEnabled)) ?? false
    }

    init(host: String = "spark-mirror.flak3dd.dev", port: Int = 22, username: String = "root", label: String = "flak3dd", isEnabled: Bool = false) {
        self.host = host
        self.port = port
        self.username = username
        self.label = label
        self.isEnabled = isEnabled
    }
}

/// Error type for SSH connection tests.
nonisolated enum SSHError: Error {
    case missingConfiguration
    case connectionFailed(String)
    case timeout
    case noBanner

    var message: String {
        switch self {
        case .missingConfiguration: "SSH not configured — enter host and password."
        case .connectionFailed(let detail): "Connection failed: \(detail)"
        case .timeout: "Connection timed out (10 s)."
        case .noBanner: "Connected but no SSH banner received."
        }
    }
}

@MainActor
@Observable
final class SSHPasswordService {
    static let shared = SSHPasswordService()

    private static let settingsKey = "ssh-password-settings"
    private static let keychainAccount = "ssh-flak3dd"

    private(set) var settings: SSHPasswordSettings

    private init() {
        settings = PersistenceStore.load(SSHPasswordSettings.self, forKey: Self.settingsKey) ?? SSHPasswordSettings()
    }

    var isConfigured: Bool {
        !settings.host.trimmingCharacters(in: .whitespaces).isEmpty &&
        !settings.username.trimmingCharacters(in: .whitespaces).isEmpty &&
        hasPassword
    }

    var hasPassword: Bool {
        KeychainService.password(account: Self.keychainAccount) != nil
    }

    func update(_ newSettings: SSHPasswordSettings) {
        settings = newSettings
        PersistenceStore.save(settings, forKey: Self.settingsKey)
    }

    func savePassword(_ password: String) {
        KeychainService.setPassword(password, account: Self.keychainAccount)
    }

    func deletePassword() {
        KeychainService.deletePassword(account: Self.keychainAccount)
    }

    /// Reads the password from the Keychain (for use during live runs).
    func password() -> String? {
        KeychainService.password(account: Self.keychainAccount)
    }

    /// Lightweight TCP probe: opens a socket to host:port, reads the SSH
    /// banner line and returns a human-readable summary. This does NOT
    /// authenticate — it just proves the host is reachable and running SSH.
    func testConnection() async throws -> String {
        guard isConfigured else { throw SSHError.missingConfiguration }

        let host = settings.host.trimmingCharacters(in: .whitespaces)
        let port = UInt16(max(1, min(settings.port, 65_535)))

        return try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue(label: "ssh-probe", qos: .userInitiated)
            queue.async {
                var hints = addrinfo()
                hints.ai_socktype = SOCK_STREAM
                hints.ai_family = AF_UNSPEC
                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(host, String(port), &hints, &result)
                guard status == 0, let info = result else {
                    let msg = String(cString: gai_strerror(status))
                    continuation.resume(throwing: SSHError.connectionFailed(msg))
                    return
                }
                defer { freeaddrinfo(result) }

                let sock = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
                guard sock >= 0 else {
                    continuation.resume(throwing: SSHError.connectionFailed("socket() failed"))
                    return
                }

                // Set a 10-second send+receive timeout.
                var tv = timeval(tv_sec: 10, tv_usec: 0)
                setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

                let connectResult = Darwin.connect(sock, info.pointee.ai_addr, info.pointee.ai_addrlen)
                guard connectResult == 0 else {
                    close(sock)
                    continuation.resume(throwing: SSHError.connectionFailed("connect() → \(errno)"))
                    return
                }

                // Read the SSH version banner (e.g. "SSH-2.0-OpenSSH_9.6").
                var buffer = [UInt8](repeating: 0, count: 256)
                let bytesRead = recv(sock, &buffer, buffer.count, 0)
                close(sock)

                if bytesRead > 0 {
                    let banner = String(bytes: buffer.prefix(bytesRead), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
                    continuation.resume(returning: "✓ \(host):\(port) · \(banner)")
                } else {
                    continuation.resume(throwing: SSHError.noBanner)
                }
            }
        }
    }
}
