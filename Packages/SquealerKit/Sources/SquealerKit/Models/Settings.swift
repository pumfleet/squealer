import Foundation

public enum FilterMode: String, Codable, Sendable, Hashable, CaseIterable {
    /// Ask the user about connections no rule covers.
    case alert
    /// Allow unknown connections without asking, and record them for review.
    case silentAllow
    /// Deny unknown connections without asking, and record them for review.
    case silentDeny
    /// Filtering disabled: everything is allowed, nothing is recorded.
    case off
}

public struct Profile: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var name: String
    public var symbol: String
    public var autoSwitch: AutoSwitchCondition?

    public init(id: UUID = UUID(), name: String, symbol: String = "circle.hexagongrid", autoSwitch: AutoSwitchCondition? = nil) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.autoSwitch = autoSwitch
    }
}

public enum AutoSwitchCondition: Hashable, Sendable, Codable {
    case wifi(ssids: [String])
    case interfaceType(InterfaceKind)
}

public enum InterfaceKind: String, Hashable, Sendable, Codable, CaseIterable {
    case wifi
    case wired
    case cellular
    case vpn
}

public enum BlocklistFormat: String, Codable, Sendable, Hashable, CaseIterable {
    case automatic
    case hosts
    case domains
    case adblock
    case littleSnitch
}

public struct BlocklistSubscription: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var name: String
    public var url: URL
    public var format: BlocklistFormat
    public var isEnabled: Bool
    /// `nil` means the blocklist applies in every profile.
    public var profileIDs: Set<UUID>?
    public var updateInterval: TimeInterval
    public var lastUpdated: Date?
    public var lastError: String?
    public var entryCount: Int

    public init(
        id: UUID = UUID(),
        name: String,
        url: URL,
        format: BlocklistFormat = .automatic,
        isEnabled: Bool = true,
        profileIDs: Set<UUID>? = nil,
        updateInterval: TimeInterval = 86_400,
        lastUpdated: Date? = nil,
        lastError: String? = nil,
        entryCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.format = format
        self.isEnabled = isEnabled
        self.profileIDs = profileIDs
        self.updateInterval = updateInterval
        self.lastUpdated = lastUpdated
        self.lastError = lastError
        self.entryCount = entryCount
    }

    public func applies(to profileID: UUID?) -> Bool {
        guard isEnabled else { return false }
        guard let profileIDs else { return true }
        return profileID.map(profileIDs.contains) ?? false
    }
}

public enum UnansweredAlertAction: String, Codable, Sendable, Hashable, CaseIterable {
    case allow
    case deny
}

public struct EngineSettings: Hashable, Sendable, Codable {
    public var mode: FilterMode
    public var activeProfileID: UUID?
    public var allowApplePlatformBinaries: Bool
    public var allowAppStoreApps: Bool
    public var allowSystemNetworkServices: Bool
    /// Any app may reach Apple and iCloud servers (push, CloudKit, Sign in with Apple…).
    public var allowAppleServices: Bool
    /// Bonjour, AirPlay, casting and other multicast discovery on the local network.
    public var allowLocalNetworkDiscovery: Bool
    public var allowIncomingFromLocalNetwork: Bool
    /// Other vendors' system extensions (VPNs, security tools) the user already approved in System Settings.
    public var allowApprovedSystemExtensions: Bool
    public var filterInbound: Bool
    public var observeDNS: Bool
    /// What happens to a connection when no Squealer app is connected to ask the user.
    public var noClientAction: UnansweredAlertAction
    /// What happens when an alert times out.
    public var alertTimeoutAction: UnansweredAlertAction
    /// Zero waits for the user indefinitely.
    public var alertTimeout: TimeInterval
    public var historyRetentionDays: Int
    /// Ask for Touch ID or the administrator password before rules or settings change.
    public var requireAuthentication: Bool

    public init(
        mode: FilterMode = .alert,
        activeProfileID: UUID? = nil,
        allowApplePlatformBinaries: Bool = true,
        allowAppStoreApps: Bool = false,
        allowSystemNetworkServices: Bool = true,
        allowAppleServices: Bool = true,
        allowLocalNetworkDiscovery: Bool = true,
        allowIncomingFromLocalNetwork: Bool = true,
        allowApprovedSystemExtensions: Bool = true,
        filterInbound: Bool = true,
        observeDNS: Bool = true,
        noClientAction: UnansweredAlertAction = .allow,
        alertTimeoutAction: UnansweredAlertAction = .deny,
        alertTimeout: TimeInterval = 0,
        historyRetentionDays: Int = 30,
        requireAuthentication: Bool = false
    ) {
        self.mode = mode
        self.activeProfileID = activeProfileID
        self.allowApplePlatformBinaries = allowApplePlatformBinaries
        self.allowAppStoreApps = allowAppStoreApps
        self.allowSystemNetworkServices = allowSystemNetworkServices
        self.allowAppleServices = allowAppleServices
        self.allowLocalNetworkDiscovery = allowLocalNetworkDiscovery
        self.allowIncomingFromLocalNetwork = allowIncomingFromLocalNetwork
        self.allowApprovedSystemExtensions = allowApprovedSystemExtensions
        self.filterInbound = filterInbound
        self.observeDNS = observeDNS
        self.noClientAction = noClientAction
        self.alertTimeoutAction = alertTimeoutAction
        self.alertTimeout = alertTimeout
        self.historyRetentionDays = historyRetentionDays
        self.requireAuthentication = requireAuthentication
    }

    /// Settings saved by older versions lack newer keys; those take their defaults instead of failing.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = EngineSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        mode = try value(.mode, defaults.mode)
        activeProfileID = try container.decodeIfPresent(UUID.self, forKey: .activeProfileID)
        allowApplePlatformBinaries = try value(.allowApplePlatformBinaries, defaults.allowApplePlatformBinaries)
        allowAppStoreApps = try value(.allowAppStoreApps, defaults.allowAppStoreApps)
        allowSystemNetworkServices = try value(.allowSystemNetworkServices, defaults.allowSystemNetworkServices)
        allowAppleServices = try value(.allowAppleServices, defaults.allowAppleServices)
        allowLocalNetworkDiscovery = try value(.allowLocalNetworkDiscovery, defaults.allowLocalNetworkDiscovery)
        allowIncomingFromLocalNetwork = try value(.allowIncomingFromLocalNetwork, defaults.allowIncomingFromLocalNetwork)
        allowApprovedSystemExtensions = try value(.allowApprovedSystemExtensions, defaults.allowApprovedSystemExtensions)
        filterInbound = try value(.filterInbound, defaults.filterInbound)
        observeDNS = try value(.observeDNS, defaults.observeDNS)
        noClientAction = try value(.noClientAction, defaults.noClientAction)
        alertTimeoutAction = try value(.alertTimeoutAction, defaults.alertTimeoutAction)
        alertTimeout = try value(.alertTimeout, defaults.alertTimeout)
        historyRetentionDays = try value(.historyRetentionDays, defaults.historyRetentionDays)
        requireAuthentication = try value(.requireAuthentication, defaults.requireAuthentication)
    }
}
