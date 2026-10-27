import Foundation
import SquealerKit

/// Localized rule descriptions for the app. (SquealerKit's `RuleDescription` is the English version the
/// command-line tool uses.)
enum RuleText {
    static func sentence(for rule: Rule, blocklistNames: [UUID: String] = [:]) -> String {
        let subject = process(rule)
        let remote = remote(rule.remote, blocklistNames: blocklistNames)
        var sentence: String = switch (rule.action, rule.direction) {
        case (.allow, .outbound): String(localized: "Allow \(subject) to connect to \(remote)")
        case (.deny, .outbound): String(localized: "Deny \(subject) to connect to \(remote)")
        case (.allow, .inbound): String(localized: "Allow incoming connections to \(subject) from \(remote)")
        case (.deny, .inbound): String(localized: "Deny incoming connections to \(subject) from \(remote)")
        case (.allow, .any): String(localized: "Allow \(subject) to exchange traffic with \(remote)")
        case (.deny, .any): String(localized: "Deny \(subject) to exchange traffic with \(remote)")
        }
        if let ports = ports(rule.ports, transport: rule.transport) {
            sentence += " " + ports
        }
        if let lifetime = lifetime(rule.lifetime) {
            sentence += " " + lifetime
        }
        return sentence
    }

    static func process(_ rule: Rule) -> String {
        let name: String = switch rule.process {
        case .any: String(localized: "any process")
        case .process(let key): rule.processName ?? key.signingID ?? key.description
        }
        guard let via = rule.via else { return name }
        return String(localized: "\(name) via \(via.signingID ?? via.description)")
    }

    static func remote(_ remote: RemoteMatcher, blocklistNames: [UUID: String] = [:]) -> String {
        switch remote {
        case .any: String(localized: "any server")
        case .host(let host): host
        case .domain(let domain): "*.\(domain)"
        case .address(let address): address.description
        case .network(let network): network.description
        case .localNetwork: String(localized: "the local network")
        case .blocklist(let id): String(localized: "hosts on \(blocklistNames[id] ?? String(localized: "a blocklist"))")
        }
    }

    static func ports(_ ports: PortMatcher, transport: TransportProtocol) -> String? {
        let proto = transport.rawValue.uppercased()
        switch ports {
        case .any:
            return transport == .any ? nil : String(localized: "over \(proto)")
        case .ranges(let ranges):
            let list = ranges.map { $0.lower == $0.upper ? Ports.label(for: $0.lower) : "\($0.lower)–\($0.upper)" }.joined(separator: ", ")
            let single = ranges.count == 1 && ranges[0].count == 1
            let phrase = single ? String(localized: "on port \(list)") : String(localized: "on ports \(list)")
            return transport == .any ? phrase : "\(phrase) (\(proto))"
        }
    }

    static func lifetime(_ lifetime: RuleLifetime) -> String? {
        switch lifetime {
        case .forever: nil
        case .untilQuit: String(localized: "until it quits")
        case .until(let date): String(localized: "until \(date.formatted(date: .omitted, time: .shortened))")
        case .untilRestart: String(localized: "until the Mac restarts")
        case .untilLogout: String(localized: "until you log out")
        }
    }
}
