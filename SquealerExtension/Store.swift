import Foundation
import GRDB
import SquealerKit

/// Persistent state, owned by the extension. Configuration is stored as Codable documents (the engine keeps
/// everything in memory anyway); traffic history is stored relationally so it can be aggregated in SQL.
final class Store: Sendable {
    let directory: URL
    private let database: DatabaseQueue

    init() throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        directory = support.appendingPathComponent("Squealer", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("Blocklists", isDirectory: true),
            withIntermediateDirectories: true
        )

        var configuration = Configuration()
        configuration.label = "SquealerStore"
        database = try DatabaseQueue(path: directory.appendingPathComponent("squealer.sqlite").path, configuration: configuration)
        try migrator.migrate(database)
    }

    var blocklistDirectory: URL {
        directory.appendingPathComponent("Blocklists", isDirectory: true)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            for table in ["rule", "profile", "blocklist"] {
                try db.create(table: table) { t in
                    t.primaryKey("id", .text)
                    t.column("document", .blob).notNull()
                }
            }
            try db.create(table: "setting") { t in
                t.primaryKey("key", .text)
                t.column("document", .blob).notNull()
            }
            for table in ["traffic_minute", "traffic_hour"] {
                try db.create(table: table) { t in
                    t.column("bucket", .integer).notNull()
                    t.column("process", .text).notNull()
                    t.column("host", .text).notNull()
                    t.column("bytes_in", .integer).notNull().defaults(to: 0)
                    t.column("bytes_out", .integer).notNull().defaults(to: 0)
                    t.column("connections", .integer).notNull().defaults(to: 0)
                    t.column("denied", .integer).notNull().defaults(to: 0)
                    t.primaryKey(["bucket", "process", "host"])
                }
                try db.create(index: "\(table)_process", on: table, columns: ["process", "bucket"])
            }
        }
        migrator.registerMigration("v2") { db in
            try db.create(table: "rule_group") { t in
                t.primaryKey("id", .text)
                t.column("document", .blob).notNull()
            }
            try db.create(table: "connection_log") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("start", .double).notNull()
                t.column("end", .double)
                t.column("process", .text).notNull()
                t.column("process_name", .text).notNull()
                t.column("host", .text).notNull()
                t.column("address", .text)
                t.column("action", .text).notNull()
                t.column("document", .blob).notNull()
            }
            try db.create(index: "connection_log_start", on: "connection_log", columns: ["start"])
            try db.create(index: "connection_log_process", on: "connection_log", columns: ["process", "start"])
        }
        return migrator
    }

    var backupDirectory: URL {
        directory.appendingPathComponent("Backups", isDirectory: true)
    }

    // MARK: Connection log

    func appendLog(_ entries: [ConnectionLogEntry]) throws {
        guard !entries.isEmpty else { return }
        try database.write { db in
            let statement = try db.cachedStatement(sql: """
                INSERT INTO connection_log (start, end, process, process_name, host, address, action, document)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """)
            for entry in entries {
                try statement.execute(arguments: [
                    entry.start.timeIntervalSince1970, entry.end?.timeIntervalSince1970, entry.process.description,
                    entry.processName, entry.host, entry.address?.description, entry.verdict.action.rawValue,
                    try XPCCoding.encode(entry),
                ])
            }
        }
    }

    func connectionLog(_ query: ConnectionLogQuery) throws -> [ConnectionLogEntry] {
        var sql = "SELECT id, document FROM connection_log WHERE start >= ?"
        var arguments: StatementArguments = [query.since.timeIntervalSince1970]
        if let until = query.until {
            sql += " AND start < ?"
            _ = arguments.append(contentsOf: [until.timeIntervalSince1970])
        }
        if let process = query.process {
            sql += " AND process = ?"
            _ = arguments.append(contentsOf: [process.description])
        }
        if let host = query.host {
            sql += " AND host = ?"
            _ = arguments.append(contentsOf: [host])
        }
        if query.deniedOnly {
            sql += " AND action = 'deny'"
        }
        if let text = query.text?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
            sql += " AND (process_name LIKE ? OR host LIKE ? OR address LIKE ?)"
            let pattern = "%\(text)%"
            _ = arguments.append(contentsOf: [pattern, pattern, pattern])
        }
        sql += " ORDER BY start DESC LIMIT ?"
        _ = arguments.append(contentsOf: [max(1, min(query.limit, 5_000))])
        return try database.read { db in
            try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap { row in
                guard var entry = try? XPCCoding.decode(ConnectionLogEntry.self, from: row["document"] as Data) else { return nil }
                entry.id = row["id"]
                return entry
            }
        }
    }

    func pruneLog(olderThan date: Date) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM connection_log WHERE start < ?", arguments: [date.timeIntervalSince1970])
        }
    }

    func clearLog() throws {
        try database.write { db in try db.execute(sql: "DELETE FROM connection_log") }
    }

    func deleteAll(table: String) throws {
        try database.write { db in try db.execute(sql: "DELETE FROM \(table)") }
    }

    // MARK: Documents

    func loadAll<T: Decodable>(_ type: T.Type, table: String) throws -> [T] {
        try database.read { db in
            try Data.fetchAll(db, sql: "SELECT document FROM \(table)").compactMap { try? XPCCoding.decode(T.self, from: $0) }
        }
    }

    func save<T: Encodable>(_ values: [(id: UUID, value: T)], table: String) throws {
        try database.write { db in
            for (id, value) in values {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO \(table) (id, document) VALUES (?, ?)",
                    arguments: [id.uuidString, try XPCCoding.encode(value)]
                )
            }
        }
    }

    func delete(_ ids: [UUID], table: String) throws {
        try database.write { db in
            for id in ids {
                try db.execute(sql: "DELETE FROM \(table) WHERE id = ?", arguments: [id.uuidString])
            }
        }
    }

    func setting<T: Decodable>(_ type: T.Type, key: String) -> T? {
        try? database.read { db in
            try Data.fetchOne(db, sql: "SELECT document FROM setting WHERE key = ?", arguments: [key])
        }.flatMap { try? XPCCoding.decode(T.self, from: $0) }
    }

    func setSetting<T: Encodable>(_ value: T, key: String) throws {
        try database.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO setting (key, document) VALUES (?, ?)",
                arguments: [key, try XPCCoding.encode(value)]
            )
        }
    }

    // MARK: Traffic

    struct TrafficDelta: Hashable, Sendable {
        var process: String
        var host: String
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
        var connections = 0
        var denied = 0
    }

    func recordTraffic(_ deltas: [TrafficDelta], at date: Date) throws {
        guard !deltas.isEmpty else { return }
        let minute = Int(date.timeIntervalSince1970) / 60 * 60
        let hour = minute / 3_600 * 3_600
        try database.write { db in
            for (table, bucket) in [("traffic_minute", minute), ("traffic_hour", hour)] {
                let statement = try db.cachedStatement(sql: """
                    INSERT INTO \(table) (bucket, process, host, bytes_in, bytes_out, connections, denied)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(bucket, process, host) DO UPDATE SET
                        bytes_in = bytes_in + excluded.bytes_in,
                        bytes_out = bytes_out + excluded.bytes_out,
                        connections = connections + excluded.connections,
                        denied = denied + excluded.denied
                    """)
                for delta in deltas {
                    try statement.execute(arguments: [
                        bucket, delta.process, delta.host,
                        Int64(clamping: delta.bytesIn), Int64(clamping: delta.bytesOut), delta.connections, delta.denied,
                    ])
                }
            }
        }
    }

    func trafficHistory(_ query: TrafficHistoryQuery) throws -> [TrafficBucket] {
        let table = query.granularity == .minute ? "traffic_minute" : "traffic_hour"
        var sql = """
            SELECT bucket, SUM(bytes_in), SUM(bytes_out), SUM(connections), SUM(denied) FROM \(table)
            WHERE bucket >= ? AND bucket < ?
            """
        var arguments: StatementArguments = [Int(query.start.timeIntervalSince1970), Int(query.end.timeIntervalSince1970)]
        if let process = query.process {
            sql += " AND process = ?"
            _ = arguments.append(contentsOf: [process.description])
        }
        if let host = query.host {
            sql += " AND host = ?"
            _ = arguments.append(contentsOf: [host])
        }
        sql += " GROUP BY bucket ORDER BY bucket"
        return try database.read { db in
            try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
                TrafficBucket(
                    start: Date(timeIntervalSince1970: TimeInterval(row[0] as Int64)),
                    bytesIn: UInt64(max(0, row[1] as Int64? ?? 0)),
                    bytesOut: UInt64(max(0, row[2] as Int64? ?? 0)),
                    connections: row[3] as Int? ?? 0,
                    denied: row[4] as Int? ?? 0
                )
            }
        }
    }

    func pruneTraffic(retentionDays: Int, now: Date = .now) throws {
        let minuteCutoff = Int(now.timeIntervalSince1970) - 48 * 3_600
        let hourCutoff = Int(now.timeIntervalSince1970) - max(1, retentionDays) * 86_400
        try database.write { db in
            try db.execute(sql: "DELETE FROM traffic_minute WHERE bucket < ?", arguments: [minuteCutoff])
            try db.execute(sql: "DELETE FROM traffic_hour WHERE bucket < ?", arguments: [hourCutoff])
        }
    }

    func clearTraffic() throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM traffic_minute")
            try db.execute(sql: "DELETE FROM traffic_hour")
        }
    }
}
