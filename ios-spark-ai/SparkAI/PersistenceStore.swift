//
//  PersistenceStore.swift
//  SparkAI
//
//  Tiny JSON-file store used for chat sessions, form presets and agent
//  config. Values live in Application Support and are written atomically.
//

import Foundation

nonisolated enum PersistenceStore {
    private static let directory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("SparkAI", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func load<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        let url = directory.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, forKey key: String) {
        let url = directory.appendingPathComponent("\(key).json")
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func remove(forKey key: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(key).json"))
    }

    /// Directory for downloaded media (e.g. rendered videos), created on demand.
    static func mediaDirectory(named name: String) -> URL {
        let dir = directory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
