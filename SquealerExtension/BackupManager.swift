import Foundation
import SquealerKit

/// Keeps JSON snapshots of the configuration: one automatically each day (the newest 14 are kept) and any the
/// user makes by hand.
struct BackupManager {
    let directory: URL
    private static let automaticToKeep = 14

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func save(_ backup: ConfigurationBackup, automatic: Bool) throws {
        let stamp = Int(backup.created.timeIntervalSince1970)
        let url = directory.appendingPathComponent("\(automatic ? "auto" : "manual")-\(stamp).json")
        try Self.encoder.encode(backup).write(to: url, options: .atomic)
        if automatic { pruneAutomatic() }
    }

    func load(_ id: String) throws -> ConfigurationBackup? {
        let url = directory.appendingPathComponent(id)
        guard url.deletingLastPathComponent() == directory, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Self.decoder.decode(ConfigurationBackup.self, from: Data(contentsOf: url))
    }

    func list() -> [BackupInfo] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }.compactMap { name in
            guard let backup = try? load(name) else { return nil }
            return BackupInfo(id: name, created: backup.created, rules: backup.rules.count, isAutomatic: name.hasPrefix("auto-"))
        }
        .sorted { $0.created > $1.created }
    }

    func needsAutomaticBackup(now: Date = .now) -> Bool {
        let newest = list().filter(\.isAutomatic).map(\.created).max()
        return newest.map { now.timeIntervalSince($0) > 86_400 } ?? true
    }

    private func pruneAutomatic() {
        for old in list().filter(\.isAutomatic).dropFirst(Self.automaticToKeep) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(old.id))
        }
    }
}
