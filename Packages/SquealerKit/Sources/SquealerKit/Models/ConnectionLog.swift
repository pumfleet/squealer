import Foundation

/// One connection, recorded when it closes (or immediately, when it's denied).
public struct ConnectionLogEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: Int64
    public var start: Date
    public var end: Date?
    public var process: ProcessKey
    public var processName: String
    public var processPath: String
    public var viaName: String?
    public var host: String
    public var address: IPAddress?
    public var port: UInt16
    public var transport: TransportProtocol
    public var direction: Direction
    public var verdict: VerdictInfo
    public var bytesIn: UInt64
    public var bytesOut: UInt64

    public init(
        id: Int64 = 0, start: Date, end: Date?, process: ProcessKey, processName: String, processPath: String,
        viaName: String?, host: String, address: IPAddress?, port: UInt16, transport: TransportProtocol,
        direction: Direction, verdict: VerdictInfo, bytesIn: UInt64, bytesOut: UInt64
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.process = process
        self.processName = processName
        self.processPath = processPath
        self.viaName = viaName
        self.host = host
        self.address = address
        self.port = port
        self.transport = transport
        self.direction = direction
        self.verdict = verdict
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }

    public var duration: TimeInterval? {
        end.map { $0.timeIntervalSince(start) }
    }
}

public struct ConnectionLogQuery: Codable, Sendable, Hashable {
    public var since: Date
    public var until: Date?
    public var process: ProcessKey?
    public var host: String?
    /// Matches app name, host or address.
    public var text: String?
    public var deniedOnly: Bool
    public var limit: Int

    public init(since: Date, until: Date? = nil, process: ProcessKey? = nil, host: String? = nil, text: String? = nil, deniedOnly: Bool = false, limit: Int = 500) {
        self.since = since
        self.until = until
        self.process = process
        self.host = host
        self.text = text
        self.deniedOnly = deniedOnly
        self.limit = limit
    }
}

public struct BackupInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var created: Date
    public var rules: Int
    public var isAutomatic: Bool

    public init(id: String, created: Date, rules: Int, isAutomatic: Bool) {
        self.id = id
        self.created = created
        self.rules = rules
        self.isAutomatic = isAutomatic
    }
}

/// Everything needed to restore Squealer's configuration. Traffic history isn't included.
public struct ConfigurationBackup: Codable, Sendable {
    public var format = "squealer-backup"
    public var version = 1
    public var created: Date
    public var settings: EngineSettings
    public var rules: [Rule]
    public var ruleGroups: [RuleGroup]
    public var profiles: [Profile]
    public var blocklists: [BlocklistSubscription]

    public init(created: Date = .now, settings: EngineSettings, rules: [Rule], ruleGroups: [RuleGroup], profiles: [Profile], blocklists: [BlocklistSubscription]) {
        self.created = created
        self.settings = settings
        self.rules = rules
        self.ruleGroups = ruleGroups
        self.profiles = profiles
        self.blocklists = blocklists
    }
}
