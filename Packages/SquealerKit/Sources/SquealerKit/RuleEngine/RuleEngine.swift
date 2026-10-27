import Foundation

/// Squealer's own code signature, so the app's own traffic (update checks, blocklist downloads) is never blocked.
public struct OwnIdentity: Hashable, Sendable {
    public var teamID: String
    public var signingIDPrefix: String

    public init(teamID: String, signingIDPrefix: String) {
        self.teamID = teamID
        self.signingIDPrefix = signingIDPrefix
    }

    func matches(_ process: ProcessIdentity) -> Bool {
        process.signer == .developerID && process.teamID == teamID
            && (process.signingID?.hasPrefix(signingIDPrefix) ?? false)
    }
}

public enum BuiltinReason: String, Codable, Sendable, Hashable {
    case applePlatform
    case appStore
    case systemService
    case appleServices
    case localDiscovery
    case localIncoming
    case systemExtension
    /// Incoming UDP no rule covers is denied without asking: it's almost never something the user initiated.
    case unsolicitedInbound
    case squealer
    case inboundFilteringOff
    case filterOff
}

public enum VerdictReason: Hashable, Sendable, Codable {
    case rule(Rule)
    case builtin(BuiltinReason)
    case silentMode
    case noClient
    case timeout
    case userOnce
}

public struct Verdict: Hashable, Sendable, Codable {
    public var action: RuleAction
    public var reason: VerdictReason

    public init(action: RuleAction, reason: VerdictReason) {
        self.action = action
        self.reason = reason
    }

    public var rule: Rule? {
        if case .rule(let rule) = reason { return rule }
        return nil
    }
}

public enum Decision: Hashable, Sendable {
    case decided(Verdict)
    /// No rule covers the flow and the engine is in alert mode: the user must be asked.
    case ask
}

/// Precedence of a matching rule. Compared lexicographically; higher wins.
public struct RuleSpecificity: Comparable, Hashable, Sendable {
    public var process: Int
    public var remote: Int
    public var ports: Int
    public var qualifiers: Int
    public var action: Int

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.process, lhs.remote, lhs.ports, lhs.qualifiers, lhs.action)
            < (rhs.process, rhs.remote, rhs.ports, rhs.qualifiers, rhs.action)
    }
}

/// An immutable, indexed snapshot of the active rule set. Rebuilt whenever rules or settings change,
/// so evaluation never touches storage and is safe to call from any thread.
public struct RuleEngine: Sendable {
    public let settings: EngineSettings
    private let rulesByProcess: [ProcessKey: [Rule]]
    private let rulesForAnyProcess: [Rule]
    private let blocklists: [UUID: BlocklistEntries]
    private let ownIdentity: OwnIdentity?

    public init(
        rules: [Rule],
        settings: EngineSettings,
        disabledGroups: Set<UUID> = [],
        blocklists: [BlocklistSubscription] = [],
        blocklistEntries: [UUID: BlocklistEntries] = [:],
        ownIdentity: OwnIdentity? = nil,
        now: Date = .now
    ) {
        self.settings = settings
        self.ownIdentity = ownIdentity

        var byProcess: [ProcessKey: [Rule]] = [:]
        var anyProcess: [Rule] = []
        for rule in rules where Self.isActive(rule, profileID: settings.activeProfileID, now: now) && !(rule.groupID.map(disabledGroups.contains) ?? false) {
            switch rule.process {
            case .any: anyProcess.append(rule)
            case .process(let key): byProcess[key, default: []].append(rule)
            }
        }

        var activeLists: [UUID: BlocklistEntries] = [:]
        for subscription in blocklists where subscription.applies(to: settings.activeProfileID) {
            guard let entries = blocklistEntries[subscription.id], !entries.isEmpty else { continue }
            activeLists[subscription.id] = entries
            anyProcess.append(Rule(
                id: subscription.id,
                process: .any,
                direction: .outbound,
                remote: .blocklist(subscription.id),
                action: .deny,
                origin: .blocklist,
                processName: subscription.name
            ))
        }

        rulesByProcess = byProcess
        rulesForAnyProcess = anyProcess
        self.blocklists = activeLists
    }

    public static func isActive(_ rule: Rule, profileID: UUID?, now: Date) -> Bool {
        guard rule.isEnabled, !rule.lifetime.isExpired(at: now) else { return false }
        guard let ruleProfile = rule.profileID else { return true }
        return ruleProfile == profileID
    }

    public func decide(_ flow: FlowContext, now: Date = .now) -> Decision {
        if settings.mode == .off {
            return .decided(Verdict(action: .allow, reason: .builtin(.filterOff)))
        }
        if let ownIdentity, ownIdentity.matches(flow.process) {
            return .decided(Verdict(action: .allow, reason: .builtin(.squealer)))
        }
        if flow.direction == .inbound, !settings.filterInbound {
            return .decided(Verdict(action: .allow, reason: .builtin(.inboundFilteringOff)))
        }
        if let rule = bestMatch(for: flow, now: now) {
            return .decided(Verdict(action: rule.action, reason: .rule(rule)))
        }
        if let builtin = builtinReason(for: flow) {
            return .decided(Verdict(action: .allow, reason: .builtin(builtin)))
        }
        switch settings.mode {
        case .alert where flow.direction == .inbound && flow.transport == .udp:
            return .decided(Verdict(action: .deny, reason: .builtin(.unsolicitedInbound)))
        case .alert: return .ask
        case .silentAllow: return .decided(Verdict(action: .allow, reason: .silentMode))
        case .silentDeny: return .decided(Verdict(action: .deny, reason: .silentMode))
        case .off: return .decided(Verdict(action: .allow, reason: .builtin(.filterOff)))
        }
    }

    /// Every active rule that matches the flow, most specific first.
    public func matchingRules(for flow: FlowContext, now: Date = .now) -> [Rule] {
        candidates(for: flow)
            .compactMap { rule in specificity(of: rule, for: flow, now: now).map { (rule, $0) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    public func bestMatch(for flow: FlowContext, now: Date = .now) -> Rule? {
        var best: (rule: Rule, score: RuleSpecificity)?
        for rule in candidates(for: flow) {
            guard let score = specificity(of: rule, for: flow, now: now) else { continue }
            if best == nil || score > best!.score {
                best = (rule, score)
            }
        }
        return best?.rule
    }

    private func candidates(for flow: FlowContext) -> [Rule] {
        var result = rulesByProcess[flow.process.key] ?? []
        if let via = flow.via?.key, via != flow.process.key {
            result += rulesByProcess[via] ?? []
        }
        return result + rulesForAnyProcess
    }

    /// Returns `nil` when the rule doesn't match the flow.
    func specificity(of rule: Rule, for flow: FlowContext, now: Date) -> RuleSpecificity? {
        guard rule.direction.covers(flow.direction), rule.transport.covers(flow.transport) else { return nil }
        guard rule.ports.matches(flow.remotePort) else { return nil }
        if case .untilQuit(let instance) = rule.lifetime, instance != flow.instance { return nil }
        if rule.lifetime.isExpired(at: now) { return nil }

        let processScore: Int
        switch rule.process {
        case .any:
            processScore = 0
        case .process(let key) where key == flow.process.key:
            if let via = rule.via {
                guard via == flow.via?.key else { return nil }
                processScore = 3
            } else {
                processScore = 2
            }
        case .process(let key) where key == flow.via?.key && rule.via == nil:
            processScore = 1
        case .process:
            return nil
        }

        guard let remoteScore = remoteSpecificity(of: rule.remote, for: flow) else { return nil }

        let portScore: Int = switch rule.ports {
        case .any: 0
        case .ranges(let ranges): ranges.count == 1 && ranges[0].count == 1 ? 2 : 1
        }
        let qualifiers = (rule.direction == .any ? 0 : 1) + (rule.transport == .any ? 0 : 1)

        return RuleSpecificity(
            process: processScore,
            remote: remoteScore,
            ports: portScore,
            qualifiers: qualifiers,
            action: rule.action == .deny ? 1 : 0
        )
    }

    private func remoteSpecificity(of matcher: RemoteMatcher, for flow: FlowContext) -> Int? {
        switch matcher {
        case .any:
            return 0
        case .host(let host):
            return flow.remoteHostname == host ? 100 : nil
        case .address(let address):
            return flow.remoteAddress == address ? 100 : nil
        case .domain(let domain):
            guard let hostname = flow.remoteHostname, Self.hostname(hostname, isWithin: domain) else { return nil }
            return 50 + min(domain.split(separator: ".").count, 40)
        case .network(let network):
            guard let address = flow.remoteAddress, network.contains(address) else { return nil }
            return 20 + network.prefixLength * 20 / address.bitWidth
        case .localNetwork:
            guard let address = flow.remoteAddress, address.isLocal else { return nil }
            return 15
        case .blocklist(let id):
            guard let entries = blocklists[id], entries.matches(hostname: flow.remoteHostname, address: flow.remoteAddress) else {
                return nil
            }
            return 10
        }
    }

    public static func hostname(_ hostname: String, isWithin domain: String) -> Bool {
        hostname == domain || hostname.hasSuffix("." + domain)
    }

    private func builtinReason(for flow: FlowContext) -> BuiltinReason? {
        let signer = flow.via?.signer ?? flow.process.signer
        if settings.allowSystemNetworkServices, isSystemNetworkService(flow) {
            return .systemService
        }
        if settings.allowApplePlatformBinaries, signer == .apple, flow.process.signer == .apple {
            return .applePlatform
        }
        if settings.allowAppStoreApps, flow.process.signer == .appStore {
            return .appStore
        }
        if settings.allowApprovedSystemExtensions, (flow.via ?? flow.process).isSystemExtension, (flow.via ?? flow.process).signer.isTrusted {
            return .systemExtension
        }
        if let address = flow.remoteAddress, address.isLocal {
            if settings.allowLocalNetworkDiscovery, Self.isDiscovery(address: address, ports: [flow.remotePort, flow.localPort]) {
                return .localDiscovery
            }
            if settings.allowIncomingFromLocalNetwork, flow.direction == .inbound {
                return .localIncoming
            }
        }
        if settings.allowAppleServices, flow.direction == .outbound, let hostname = flow.remoteHostname,
           Self.appleServiceDomains.contains(where: { Self.hostname(hostname, isWithin: $0) }) {
            return .appleServices
        }
        return nil
    }

    /// Apple and iCloud endpoints third-party apps use through system frameworks (push, CloudKit, Sign in with
    /// Apple, StoreKit, maps tiles).
    private static let appleServiceDomains = [
        "apple.com", "icloud.com", "icloud-content.com", "apple-cloudkit.com", "mzstatic.com", "cdn-apple.com",
        "aaplimg.com", "apple-dns.net", "apple.news", "me.com", "itunes.com", "appattest.apple.com",
    ]

    private static let discoveryPorts: Set<UInt16> = [5353, 1900, 5350, 5351, 137, 138, 3702]
    private static let multicast = ["224.0.0.0/4", "255.255.255.255/32", "ff00::/8"].compactMap(IPNetwork.init)

    private static func isDiscovery(address: IPAddress, ports: [UInt16]) -> Bool {
        ports.contains(where: discoveryPorts.contains) || multicast.contains { $0.contains(address) }
    }

    private static let systemServices: Set<String> = [
        "com.apple.mDNSResponder", "com.apple.configd", "com.apple.timed", "com.apple.bootpd",
    ]

    /// Checks the process that actually opened the socket, so DNS lookups mDNSResponder makes on an app's
    /// behalf count as a system service.
    private func isSystemNetworkService(_ flow: FlowContext) -> Bool {
        let actual = flow.via ?? flow.process
        guard actual.signer == .apple, let id = actual.signingID else { return false }
        if Self.systemServices.contains(id) { return true }
        if flow.transport == .udp, [53, 67, 68, 123].contains(flow.remotePort) { return true }
        return false
    }
}
