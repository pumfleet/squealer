import Foundation

public enum RuleAction: String, Codable, Sendable, Hashable, CaseIterable {
    case allow
    case deny
}

public enum Direction: String, Codable, Sendable, Hashable, CaseIterable {
    case outbound
    case inbound
    case any

    public func covers(_ other: Direction) -> Bool {
        self == .any || self == other
    }
}

public enum TransportProtocol: String, Codable, Sendable, Hashable, CaseIterable {
    case tcp
    case udp
    case any

    public func covers(_ other: TransportProtocol) -> Bool {
        self == .any || self == other
    }
}

public enum ProcessMatcher: Hashable, Sendable, Codable {
    case any
    case process(ProcessKey)

    public func matches(_ key: ProcessKey?) -> Bool {
        switch self {
        case .any: true
        case .process(let expected): key == expected
        }
    }

    public func covers(_ other: ProcessMatcher) -> Bool {
        self == .any || self == other
    }
}

public enum RemoteMatcher: Hashable, Sendable, Codable {
    case any
    case host(String)
    case domain(String)
    case address(IPAddress)
    case network(IPNetwork)
    case localNetwork
    case blocklist(UUID)

    /// Normalises user input so host/domain comparisons are case-insensitive and trailing-dot free.
    public static func normalize(_ name: String) -> String {
        var lowered = name.lowercased().trimmingCharacters(in: .whitespaces)
        while lowered.hasSuffix(".") { lowered.removeLast() }
        if lowered.hasPrefix("*.") { lowered.removeFirst(2) }
        return lowered
    }
}

public struct PortRange: Hashable, Sendable, Codable {
    public var lower: UInt16
    public var upper: UInt16

    public init(_ port: UInt16) {
        lower = port
        upper = port
    }

    public init(_ lower: UInt16, _ upper: UInt16) {
        self.lower = min(lower, upper)
        self.upper = max(lower, upper)
    }

    public func contains(_ port: UInt16) -> Bool {
        (lower...upper).contains(port)
    }

    public var count: Int { Int(upper) - Int(lower) + 1 }
}

public enum PortMatcher: Hashable, Sendable, Codable {
    case any
    case ranges([PortRange])

    public static func port(_ port: UInt16) -> PortMatcher { .ranges([PortRange(port)]) }

    public func matches(_ port: UInt16) -> Bool {
        switch self {
        case .any: true
        case .ranges(let ranges): ranges.contains { $0.contains(port) }
        }
    }

    public func covers(_ other: PortMatcher) -> Bool {
        switch (self, other) {
        case (.any, _): true
        case (.ranges, .any): false
        case let (.ranges(mine), .ranges(theirs)):
            theirs.allSatisfy { range in mine.contains { $0.lower <= range.lower && $0.upper >= range.upper } }
        }
    }
}

public enum RuleLifetime: Hashable, Sendable, Codable {
    case forever
    case untilQuit(ProcessInstance)
    case until(Date)
    /// Removed when the Mac restarts; holds the boot time it was created under.
    case untilRestart(bootTime: Date)
    /// Removed when the user logs out; holds the login session it was created in.
    case untilLogout(session: String)

    public func isExpired(at date: Date) -> Bool {
        if case .until(let expiry) = self { return expiry <= date }
        return false
    }
}

public enum RuleOrigin: String, Codable, Sendable, Hashable {
    case user
    case alert
    case builtin
    case blocklist
    case imported
    case subscription
}

public struct Rule: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var process: ProcessMatcher
    /// When set, the rule only applies to connections made on behalf of `process` by this helper.
    public var via: ProcessKey?
    public var direction: Direction
    public var remote: RemoteMatcher
    public var ports: PortMatcher
    public var transport: TransportProtocol
    public var action: RuleAction
    public var lifetime: RuleLifetime
    /// `nil` means the rule applies in every profile.
    public var profileID: UUID?
    public var isEnabled: Bool
    public var note: String
    public var origin: RuleOrigin
    /// Cached presentation details for the process; rules never match on these.
    public var processName: String?
    public var processPath: String?
    public var groupID: UUID?
    /// False for rules created in bulk (imports, trusting installed apps, subscriptions) until the user confirms them.
    public var isApproved: Bool
    public var createdAt: Date
    public var modifiedAt: Date

    public init(
        id: UUID = UUID(),
        process: ProcessMatcher,
        via: ProcessKey? = nil,
        direction: Direction = .outbound,
        remote: RemoteMatcher = .any,
        ports: PortMatcher = .any,
        transport: TransportProtocol = .any,
        action: RuleAction,
        lifetime: RuleLifetime = .forever,
        profileID: UUID? = nil,
        isEnabled: Bool = true,
        note: String = "",
        origin: RuleOrigin = .user,
        processName: String? = nil,
        processPath: String? = nil,
        groupID: UUID? = nil,
        isApproved: Bool = true,
        createdAt: Date = .now
    ) {
        self.id = id
        self.process = process
        self.via = via
        self.direction = direction
        self.remote = remote
        self.ports = ports
        self.transport = transport
        self.action = action
        self.lifetime = lifetime
        self.profileID = profileID
        self.isEnabled = isEnabled
        self.note = note
        self.origin = origin
        self.processName = processName
        self.processPath = processPath
        self.groupID = groupID
        self.isApproved = isApproved
        self.createdAt = createdAt
        self.modifiedAt = createdAt
    }

    /// Rules saved before a field existed decode with that field's default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        process = try container.decode(ProcessMatcher.self, forKey: .process)
        via = try container.decodeIfPresent(ProcessKey.self, forKey: .via)
        direction = try container.decodeIfPresent(Direction.self, forKey: .direction) ?? .outbound
        remote = try container.decodeIfPresent(RemoteMatcher.self, forKey: .remote) ?? .any
        ports = try container.decodeIfPresent(PortMatcher.self, forKey: .ports) ?? .any
        transport = try container.decodeIfPresent(TransportProtocol.self, forKey: .transport) ?? .any
        action = try container.decode(RuleAction.self, forKey: .action)
        lifetime = try container.decodeIfPresent(RuleLifetime.self, forKey: .lifetime) ?? .forever
        profileID = try container.decodeIfPresent(UUID.self, forKey: .profileID)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        origin = try container.decodeIfPresent(RuleOrigin.self, forKey: .origin) ?? .user
        processName = try container.decodeIfPresent(String.self, forKey: .processName)
        processPath = try container.decodeIfPresent(String.self, forKey: .processPath)
        groupID = try container.decodeIfPresent(UUID.self, forKey: .groupID)
        isApproved = try container.decodeIfPresent(Bool.self, forKey: .isApproved) ?? true
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? createdAt
    }
}

public struct RuleGroup: Identifiable, Hashable, Sendable, Codable {
    public struct Subscription: Hashable, Sendable, Codable {
        public var url: URL
        public var updateInterval: TimeInterval
        public var lastUpdated: Date?
        public var lastError: String?
        /// Rules for apps that aren't installed here, so they couldn't be tied to a code signature.
        public var skippedProcesses: [String]

        public init(url: URL, updateInterval: TimeInterval = 86_400, lastUpdated: Date? = nil, lastError: String? = nil, skippedProcesses: [String] = []) {
            self.url = url
            self.updateInterval = updateInterval
            self.lastUpdated = lastUpdated
            self.lastError = lastError
            self.skippedProcesses = skippedProcesses
        }
    }

    public var id: UUID
    public var name: String
    public var note: String
    public var isEnabled: Bool
    /// Subscribed groups are replaced wholesale on every update, so their rules aren't editable.
    public var subscription: Subscription?

    public init(id: UUID = UUID(), name: String, note: String = "", isEnabled: Bool = true, subscription: Subscription? = nil) {
        self.id = id
        self.name = name
        self.note = note
        self.isEnabled = isEnabled
        self.subscription = subscription
    }
}
