import Foundation

public enum EngineRequest: Codable, Sendable {
    case hello(clientVersion: String)
    case setSettings(EngineSettings)
    case upsertRules([Rule])
    case deleteRules([UUID])
    case upsertProfile(Profile)
    case deleteProfile(UUID)
    case upsertBlocklist(BlocklistSubscription)
    case deleteBlocklist(UUID)
    case refreshBlocklist(UUID)
    case resolveAlert(AlertDecision)
    case trafficHistory(TrafficHistoryQuery)
    case dismissReview([UUID])
    case clearHistory
    case upsertRuleGroup(RuleGroup)
    /// Deleting a group either deletes its rules or keeps them ungrouped.
    case deleteRuleGroup(UUID, deleteRules: Bool)
    case refreshRuleGroup(UUID)
    case connectionLog(ConnectionLogQuery)
    case listBackups
    case createBackup
    case restoreBackup(String)
    case restoreConfiguration(ConfigurationBackup)
    case exportConfiguration
    /// Removes "until logout" rules from every login session except this one.
    case endLogoutSessions(except: String)
    /// Deletes everything the extension stores, just before it's uninstalled.
    case eraseAllData
}

extension EngineRequest {
    /// Requests that only read state; the command-line tool may send these without root.
    public var isReadOnly: Bool {
        switch self {
        case .hello, .trafficHistory, .connectionLog, .listBackups, .exportConfiguration: true
        default: false
        }
    }
}

public enum EngineResponse: Codable, Sendable {
    case ok
    case failure(String)
    case snapshot(EngineSnapshot)
    case history([TrafficBucket])
    case blocklist(BlocklistSubscription)
    case ruleGroup(RuleGroup)
    case log([ConnectionLogEntry])
    case backups([BackupInfo])
    case configuration(ConfigurationBackup)
}

public enum EngineEvent: Codable, Sendable {
    case alert(ConnectionAlert)
    case alertWithdrawn(UUID)
    case traffic(TrafficUpdate)
    case rules([Rule])
    case settings(EngineSettings)
    case profiles([Profile])
    case blocklists([BlocklistSubscription])
    case review([ReviewItem])
    case ruleGroups([RuleGroup])
}

public struct EngineSnapshot: Codable, Sendable {
    public var engineVersion: String
    public var settings: EngineSettings
    public var rules: [Rule]
    public var ruleGroups: [RuleGroup]
    public var profiles: [Profile]
    public var blocklists: [BlocklistSubscription]
    public var pendingAlerts: [ConnectionAlert]
    public var connections: [ConnectionSummary]
    public var review: [ReviewItem]

    public init(
        engineVersion: String,
        settings: EngineSettings,
        rules: [Rule],
        ruleGroups: [RuleGroup],
        profiles: [Profile],
        blocklists: [BlocklistSubscription],
        pendingAlerts: [ConnectionAlert],
        connections: [ConnectionSummary],
        review: [ReviewItem]
    ) {
        self.engineVersion = engineVersion
        self.settings = settings
        self.rules = rules
        self.ruleGroups = ruleGroups
        self.profiles = profiles
        self.blocklists = blocklists
        self.pendingAlerts = pendingAlerts
        self.connections = connections
        self.review = review
    }
}

/// A connection waiting for the user. Repeated attempts to the same endpoint from the same process are
/// folded into one alert.
public struct ConnectionAlert: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var flow: FlowContext
    public var attempts: Int
    public var firstSeen: Date
    public var deadline: Date

    public init(id: UUID = UUID(), flow: FlowContext, attempts: Int = 1, firstSeen: Date = .now, deadline: Date) {
        self.id = id
        self.flow = flow
        self.attempts = attempts
        self.firstSeen = firstSeen
        self.deadline = deadline
    }
}

public struct AlertDecision: Codable, Sendable, Hashable {
    public enum Outcome: Codable, Sendable, Hashable {
        /// Apply the action to the waiting connections only.
        case once(RuleAction)
        /// Persist a rule; waiting connections it covers are resolved by it.
        case rule(Rule)
        /// Let the connection through for now and add it to the review queue.
        case later
    }

    public var alertID: UUID
    public var outcome: Outcome

    public init(alertID: UUID, outcome: Outcome) {
        self.alertID = alertID
        self.outcome = outcome
    }
}

/// How a connection was decided, compact enough to stream for every connection.
public struct VerdictInfo: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case rule
        case builtin
        case silent
        case noClient
        case timeout
        case once
        case pending
    }

    public var action: RuleAction
    public var kind: Kind
    public var ruleID: UUID?
    public var builtin: BuiltinReason?

    public init(action: RuleAction, kind: Kind, ruleID: UUID? = nil, builtin: BuiltinReason? = nil) {
        self.action = action
        self.kind = kind
        self.ruleID = ruleID
        self.builtin = builtin
    }

    public init(_ verdict: Verdict) {
        action = verdict.action
        switch verdict.reason {
        case .rule(let rule):
            kind = .rule
            ruleID = rule.id
        case .builtin(let reason):
            kind = .builtin
            builtin = reason
        case .silentMode: kind = .silent
        case .noClient: kind = .noClient
        case .timeout: kind = .timeout
        case .userOnce: kind = .once
        }
    }
}

/// Aggregated statistics for one (process, endpoint) pair.
public struct ConnectionSummary: Codable, Sendable, Identifiable, Hashable {
    public struct ID: Codable, Sendable, Hashable {
        public var process: ProcessKey
        public var via: ProcessKey?
        public var endpoint: EndpointKey

        public init(process: ProcessKey, via: ProcessKey?, endpoint: EndpointKey) {
            self.process = process
            self.via = via
            self.endpoint = endpoint
        }
    }

    public var id: ID
    public var process: ProcessIdentity
    public var via: ProcessIdentity?
    public var remoteAddress: IPAddress?
    public var hostnameSource: HostnameSource
    public var lastVerdict: VerdictInfo
    public var bytesIn: UInt64
    public var bytesOut: UInt64
    /// Bytes per second over the most recent reporting interval.
    public var rateIn: Double
    public var rateOut: Double
    public var activeFlows: Int
    public var totalFlows: Int
    public var deniedFlows: Int
    public var firstSeen: Date
    public var lastSeen: Date

    public init(
        id: ID,
        process: ProcessIdentity,
        via: ProcessIdentity?,
        remoteAddress: IPAddress?,
        hostnameSource: HostnameSource,
        lastVerdict: VerdictInfo,
        bytesIn: UInt64 = 0,
        bytesOut: UInt64 = 0,
        rateIn: Double = 0,
        rateOut: Double = 0,
        activeFlows: Int = 0,
        totalFlows: Int = 0,
        deniedFlows: Int = 0,
        firstSeen: Date = .now,
        lastSeen: Date = .now
    ) {
        self.id = id
        self.process = process
        self.via = via
        self.remoteAddress = remoteAddress
        self.hostnameSource = hostnameSource
        self.lastVerdict = lastVerdict
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.rateIn = rateIn
        self.rateOut = rateOut
        self.activeFlows = activeFlows
        self.totalFlows = totalFlows
        self.deniedFlows = deniedFlows
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }

    public var endpoint: EndpointKey { id.endpoint }
}

public struct TrafficUpdate: Codable, Sendable {
    public var timestamp: Date
    public var connections: [ConnectionSummary]
    public var totalRateIn: Double
    public var totalRateOut: Double

    public init(timestamp: Date, connections: [ConnectionSummary], totalRateIn: Double, totalRateOut: Double) {
        self.timestamp = timestamp
        self.connections = connections
        self.totalRateIn = totalRateIn
        self.totalRateOut = totalRateOut
    }
}

public struct TrafficHistoryQuery: Codable, Sendable, Hashable {
    public enum Granularity: String, Codable, Sendable, Hashable {
        case minute
        case hour
    }

    public var start: Date
    public var end: Date
    public var granularity: Granularity
    public var process: ProcessKey?
    public var host: String?

    public init(start: Date, end: Date, granularity: Granularity, process: ProcessKey? = nil, host: String? = nil) {
        self.start = start
        self.end = end
        self.granularity = granularity
        self.process = process
        self.host = host
    }
}

public struct TrafficBucket: Codable, Sendable, Hashable, Identifiable {
    public var start: Date
    public var bytesIn: UInt64
    public var bytesOut: UInt64
    public var connections: Int
    public var denied: Int

    public var id: Date { start }

    public init(start: Date, bytesIn: UInt64, bytesOut: UInt64, connections: Int, denied: Int) {
        self.start = start
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.connections = connections
        self.denied = denied
    }
}

/// A connection decided without the user (silent mode, no app running, "decide later") that they may want
/// to turn into a rule.
public struct ReviewItem: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var flow: FlowContext
    public var action: RuleAction
    public var reason: VerdictInfo.Kind
    public var attempts: Int
    public var lastSeen: Date

    public init(id: UUID = UUID(), flow: FlowContext, action: RuleAction, reason: VerdictInfo.Kind, attempts: Int = 1, lastSeen: Date = .now) {
        self.id = id
        self.flow = flow
        self.action = action
        self.reason = reason
        self.attempts = attempts
        self.lastSeen = lastSeen
    }

    public var groupKey: ConnectionSummary.ID {
        ConnectionSummary.ID(process: flow.process.key, via: flow.via?.key, endpoint: flow.endpointKey)
    }
}
