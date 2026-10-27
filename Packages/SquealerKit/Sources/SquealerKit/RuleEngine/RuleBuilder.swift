import Foundation

/// The choices offered in a connection alert, turned into a rule.
public struct AlertScope: Hashable, Sendable, Codable {
    public enum Remote: String, Hashable, Sendable, Codable, CaseIterable {
        case host
        case domain
        case any
    }

    public enum Ports: String, Hashable, Sendable, Codable, CaseIterable {
        case this
        case any
    }

    public enum Duration: String, Hashable, Sendable, Codable, CaseIterable {
        case once
        case minute
        case untilQuit
        case hour
        case untilRestart
        case untilLogout
        case forever
    }

    public var remote: Remote
    public var ports: Ports
    public var duration: Duration

    public init(remote: Remote = .domain, ports: Ports = .any, duration: Duration = .forever) {
        self.remote = remote
        self.ports = ports
        self.duration = duration
    }
}

/// What "until restart" and "until logout" rules are tied to.
public struct SessionInfo: Hashable, Sendable {
    public var bootTime: Date
    public var loginSession: String

    public init(bootTime: Date, loginSession: String) {
        self.bootTime = bootTime
        self.loginSession = loginSession
    }
}

public enum RuleBuilder {
    public static func rule(
        for flow: FlowContext,
        action: RuleAction,
        scope: AlertScope,
        profileID: UUID? = nil,
        session: SessionInfo = SessionInfo(bootTime: .distantPast, loginSession: ""),
        now: Date = .now
    ) -> Rule? {
        let lifetime: RuleLifetime
        switch scope.duration {
        case .once: return nil
        case .minute: lifetime = .until(now + 60)
        case .untilQuit: lifetime = .untilQuit(flow.instance)
        case .hour: lifetime = .until(now + 3_600)
        case .untilRestart: lifetime = .untilRestart(bootTime: session.bootTime)
        case .untilLogout: lifetime = .untilLogout(session: session.loginSession)
        case .forever: lifetime = .forever
        }
        return Rule(
            process: .process(flow.process.key),
            via: nil,
            direction: flow.direction,
            remote: remoteMatcher(for: flow, scope: scope.remote),
            ports: scope.ports == .this && flow.direction == .outbound ? .port(flow.remotePort) : .any,
            transport: .any,
            action: action,
            lifetime: lifetime,
            profileID: profileID,
            origin: .alert,
            processName: flow.process.displayName,
            processPath: flow.process.bundlePath ?? flow.process.path,
            createdAt: now
        )
    }

    public static func remoteMatcher(for flow: FlowContext, scope: AlertScope.Remote) -> RemoteMatcher {
        switch scope {
        case .any:
            return .any
        case .host:
            if let hostname = flow.remoteHostname { return .host(hostname) }
            return flow.remoteAddress.map(RemoteMatcher.address) ?? .any
        case .domain:
            // For devices on the LAN the useful "wider" scope is the whole local network, not a DNS domain.
            if flow.remoteAddress?.isLocal == true { return .localNetwork }
            if let hostname = flow.remoteHostname { return .domain(DomainName.registrableDomain(of: hostname)) }
            return flow.remoteAddress.map(RemoteMatcher.address) ?? .any
        }
    }
}

public enum DomainName {
    /// Second-level labels under which registrations happen (e.g. `example.co.uk`). Not the full Public Suffix
    /// List, but covers the common cases; the rule editor lets users adjust the domain anyway.
    private static let multiLabelSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "ltd.uk", "plc.uk", "net.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au",
        "co.nz", "org.nz", "net.nz", "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp",
        "com.br", "net.br", "org.br", "com.cn", "net.cn", "org.cn", "gov.cn",
        "com.mx", "com.ar", "com.tr", "com.tw", "com.hk", "com.sg", "com.my", "co.in", "co.kr", "co.za",
        "co.il", "com.ua", "com.pl", "com.es", "co.id", "co.th", "com.vn", "com.ph", "com.pk",
        "github.io", "herokuapp.com", "cloudfront.net", "amazonaws.com", "azurewebsites.net",
        "appspot.com", "blogspot.com", "vercel.app", "netlify.app", "pages.dev", "workers.dev",
        "fastly.net", "akamaiedge.net", "akamai.net", "edgekey.net", "edgesuite.net",
    ]

    public static func registrableDomain(of hostname: String) -> String {
        let labels = hostname.split(separator: ".")
        guard labels.count > 2 else { return hostname }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        let keep = multiLabelSuffixes.contains(lastTwo) ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }
}
