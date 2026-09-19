//
//  CloudConsent.swift
//  SparkAI
//
//  Tracks per-surface acceptance of the third-party AI disclosures. Chat
//  messages and page scans send user-entered content to external providers,
//  so each carries its own disclosure text and persisted consent key.
//

import Foundation

nonisolated enum CloudConsent {
    /// Features that transmit user content to external AI providers.
    enum Surface: String {
        /// Chat messages → Featherless AI / Rork inference gateway.
        case chat
        /// Page scan text → Rork inference gateway.
        case pageScan
    }

    /// True once the user has acknowledged the disclosure for this surface.
    static func isAccepted(_ surface: Surface) -> Bool {
        UserDefaults.standard.bool(forKey: "cloud-disclosure-\(surface.rawValue)")
    }

    static func accept(_ surface: Surface) {
        UserDefaults.standard.set(true, forKey: "cloud-disclosure-\(surface.rawValue)")
    }
}
