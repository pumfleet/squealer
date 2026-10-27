import Foundation

public enum RuleDescription {
    public static func sentence(for rule: Rule, blocklistNames: [UUID: String] = [:]) -> String {
        let verb = rule.action == .allow ? "Allow" : "Deny"
        let subject = processPhrase(rule)
        let remote = remotePhrase(rule.remote, blocklistNames: blocklistNames)
        var sentence: String
        switch rule.direction {
        case .outbound:
            sentence = "\(verb) \(subject) to connect to \(remote)"
        case .inbound:
            sentence = "\(verb) incoming connections to \(subject) from \(remote)"
        case .any:
            sentence = "\(verb) \(subject) to exchange traffic with \(remote)"
        }
        if let ports = portsPhrase(rule.ports, transport: rule.transport) {
            sentence += " \(ports)"
        }
        if let lifetime = lifetimePhrase(rule.lifetime) {
            sentence += " \(lifetime)"
        }
        return sentence
    }

    public static func processPhrase(_ rule: Rule) -> String {
        let name: String = switch rule.process {
        case .any: "any process"
        case .process(let key): rule.processName ?? key.signingID ?? key.description
        }
        guard let via = rule.via else { return name }
        return "\(name) via \(via.signingID ?? via.description)"
    }

    public static func remotePhrase(_ remote: RemoteMatcher, blocklistNames: [UUID: String] = [:]) -> String {
        switch remote {
        case .any: "any server"
        case .host(let host): host
        case .domain(let domain): "*.\(domain)"
        case .address(let address): address.description
        case .network(let network): network.description
        case .localNetwork: "the local network"
        case .blocklist(let id): "hosts on \(blocklistNames[id] ?? "a blocklist")"
        }
    }

    public static func portsPhrase(_ ports: PortMatcher, transport: TransportProtocol) -> String? {
        let protocolSuffix = transport == .any ? "" : " (\(transport.rawValue.uppercased()))"
        switch ports {
        case .any:
            return transport == .any ? nil : "over \(transport.rawValue.uppercased())"
        case .ranges(let ranges):
            let list = ranges.map { $0.lower == $0.upper ? Ports.label(for: $0.lower) : "\($0.lower)–\($0.upper)" }
            let noun = ranges.count == 1 && ranges[0].count == 1 ? "port" : "ports"
            return "on \(noun) \(list.joined(separator: ", "))\(protocolSuffix)"
        }
    }

    public static func lifetimePhrase(_ lifetime: RuleLifetime) -> String? {
        switch lifetime {
        case .forever: nil
        case .untilQuit: "until it quits"
        case .until(let date): "until \(date.formatted(date: .omitted, time: .shortened))"
        case .untilRestart: "until the Mac restarts"
        case .untilLogout: "until you log out"
        }
    }
}

public enum Ports {
    private static let services: [UInt16: String] = [
        20: "FTP data", 21: "FTP", 22: "SSH", 23: "Telnet", 25: "SMTP", 53: "DNS", 67: "DHCP", 68: "DHCP",
        80: "HTTP", 110: "POP3", 123: "NTP", 143: "IMAP", 161: "SNMP", 389: "LDAP", 443: "HTTPS",
        445: "SMB", 465: "SMTPS", 500: "IKE", 514: "Syslog", 548: "AFP", 587: "Submission", 631: "IPP",
        853: "DNS over TLS", 873: "rsync", 993: "IMAPS", 995: "POP3S", 1194: "OpenVPN", 1883: "MQTT",
        3283: "Remote Desktop", 3306: "MySQL", 3389: "RDP", 3478: "STUN", 4500: "IPsec NAT-T",
        5060: "SIP", 5222: "XMPP", 5223: "Apple Push", 5228: "Google Push", 5353: "mDNS", 5432: "PostgreSQL",
        5900: "VNC", 6379: "Redis", 8080: "HTTP alt", 8443: "HTTPS alt", 9418: "Git", 27017: "MongoDB",
        51820: "WireGuard",
    ]

    public static func serviceName(for port: UInt16) -> String? {
        services[port]
    }

    public static func label(for port: UInt16) -> String {
        guard let name = services[port] else { return "\(port)" }
        return "\(port) (\(name))"
    }
}
