import Foundation

public enum RuleIssue: Hashable, Sendable {
    /// Another rule matches exactly the same connections with the same action.
    case duplicate(of: UUID)
    /// A deny rule with identical scope always wins over this allow rule.
    case overriddenBy(UUID)
    /// A broader rule already gives every matching connection the same verdict.
    case redundant(with: UUID)
}

public enum RuleAnalysis {
    public static func issues(for rule: Rule, in rules: [Rule]) -> [RuleIssue] {
        guard rule.isEnabled else { return [] }
        let others = rules.filter { $0.isEnabled && $0.id != rule.id && $0.origin != .blocklist }
        var issues: [RuleIssue] = []
        for other in others {
            if sameScope(other, rule) {
                if other.action == rule.action {
                    issues.append(.duplicate(of: other.id))
                } else if other.action == .deny {
                    issues.append(.overriddenBy(other.id))
                }
            } else if other.action == rule.action, covers(other, rule) {
                let hasCarveOut = others.contains { candidate in
                    candidate.action != rule.action && candidate.id != other.id && covers(other, candidate)
                }
                if !hasCarveOut {
                    issues.append(.redundant(with: other.id))
                }
            }
        }
        return issues
    }

    static func sameScope(_ a: Rule, _ b: Rule) -> Bool {
        a.process == b.process && a.via == b.via && a.direction == b.direction && a.remote == b.remote
            && a.ports == b.ports && a.transport == b.transport && a.profileID == b.profileID
    }

    /// True when every connection `inner` matches is also matched by `outer`.
    public static func covers(_ outer: Rule, _ inner: Rule) -> Bool {
        guard outer.profileID == nil || outer.profileID == inner.profileID else { return false }
        guard outer.process.covers(inner.process) else { return false }
        guard outer.via == nil || outer.via == inner.via else { return false }
        guard outer.direction.covers(inner.direction), outer.transport.covers(inner.transport) else { return false }
        guard outer.ports.covers(inner.ports) else { return false }
        return covers(outer.remote, inner.remote)
    }

    public static func covers(_ outer: RemoteMatcher, _ inner: RemoteMatcher) -> Bool {
        if outer == inner || outer == .any { return true }
        switch (outer, inner) {
        case let (.domain(domain), .host(host)), let (.domain(domain), .domain(host)):
            return RuleEngine.hostname(host, isWithin: domain)
        case let (.network(network), .address(address)):
            return network.contains(address)
        case let (.network(network), .network(innerNetwork)):
            return network.contains(innerNetwork)
        case let (.localNetwork, .address(address)):
            return address.isLocal
        case let (.localNetwork, .network(network)):
            return IPNetwork.localNetworks.contains { $0.contains(network) }
        default:
            return false
        }
    }
}
