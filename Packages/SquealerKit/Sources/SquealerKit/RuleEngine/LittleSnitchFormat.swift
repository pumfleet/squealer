import Foundation

/// Reads and writes Little Snitch's documented `.lsrules` JSON format, so rule groups can be shared with and
/// subscribed from the wider Little Snitch ecosystem.
public enum LittleSnitchFormat {
    public struct Result: Sendable {
        public var name: String?
        public var description: String?
        public var rules: [Rule]
        /// Process paths that couldn't be resolved to a code signature on this Mac.
        public var skipped: [String]
    }

    public enum FormatError: Error, Equatable {
        case notLittleSnitchFile
    }

    private struct File: Codable {
        var name: String?
        var description: String?
        var rules: [Entry]?
        var deniedRemoteDomains: [String]?
        var deniedRemoteHosts: [String]?
        var deniedRemoteAddresses: [String]?

        enum CodingKeys: String, CodingKey {
            case name, description, rules
            case deniedRemoteDomains = "denied-remote-domains"
            case deniedRemoteHosts = "denied-remote-hosts"
            case deniedRemoteAddresses = "denied-remote-addresses"
        }
    }

    private struct Entry: Codable {
        var process: String?
        var via: String?
        var action: String?
        var direction: String?
        var remote: String?
        var remoteHosts: StringList?
        var remoteDomains: StringList?
        var remoteAddresses: StringList?
        var ports: String?
        var `protocol`: String?
        var disabled: Bool?
        var notes: String?

        enum CodingKeys: String, CodingKey {
            case process, via, action, direction, remote, ports, `protocol`, disabled, notes
            case remoteHosts = "remote-hosts"
            case remoteDomains = "remote-domains"
            case remoteAddresses = "remote-addresses"
        }
    }

    private struct StringList: Codable {
        var values: [String]

        init(_ values: [String]) {
            self.values = values
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let single = try? container.decode(String.self) {
                values = single.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } else {
                values = try container.decode([String].self)
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            if values.count == 1 { try container.encode(values[0]) } else { try container.encode(values) }
        }
    }

    public static func isLittleSnitchFile(_ data: Data) -> Bool {
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { return false }
        return file.rules != nil || file.deniedRemoteDomains != nil || file.deniedRemoteHosts != nil || file.deniedRemoteAddresses != nil
    }

    /// `resolve` turns a process path into the code-signing identity rules match on; it returns `nil` for apps
    /// that aren't installed.
    public static func parse(_ data: Data, origin: RuleOrigin, groupID: UUID? = nil, resolve: (String) -> ProcessIdentity?) throws -> Result {
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { throw FormatError.notLittleSnitchFile }
        var rules: [Rule] = []
        var skipped: [String] = []
        var cache: [String: ProcessIdentity?] = [:]

        func identity(_ path: String) -> ProcessIdentity? {
            if let cached = cache[path] { return cached }
            let resolved = resolve(path)
            cache[path] = resolved
            return resolved
        }

        func make(_ process: ProcessMatcher, name: String?, path: String?, via: ProcessKey? = nil, direction: Direction = .outbound,
                  remote: RemoteMatcher, ports: PortMatcher = .any, transport: TransportProtocol = .any,
                  action: RuleAction, enabled: Bool = true, note: String = "") -> Rule {
            Rule(
                process: process, via: via, direction: direction, remote: remote, ports: ports, transport: transport,
                action: action, isEnabled: enabled, note: note, origin: origin, processName: name, processPath: path,
                groupID: groupID, isApproved: origin != .imported
            )
        }

        for entry in file.rules ?? [] {
            var process = ProcessMatcher.any
            var name: String?
            if let path = entry.process, path != "any" {
                guard let resolved = identity(path) else {
                    skipped.append(path)
                    continue
                }
                process = .process(resolved.key)
                name = resolved.displayName
            }
            var via: ProcessKey?
            if let viaPath = entry.via {
                guard let resolved = identity(viaPath) else {
                    skipped.append(viaPath)
                    continue
                }
                via = resolved.key
            }

            var remotes: [RemoteMatcher] = []
            switch entry.remote {
            case "local-net": remotes.append(.localNetwork)
            default: break
            }
            remotes += (entry.remoteHosts?.values ?? []).map { IPAddress($0).map(RemoteMatcher.address) ?? .host(RemoteMatcher.normalize($0)) }
            remotes += (entry.remoteDomains?.values ?? []).map { .domain(RemoteMatcher.normalize($0)) }
            remotes += (entry.remoteAddresses?.values ?? []).compactMap { IPNetwork($0).map { $0.prefixLength == $0.address.bitWidth ? .address($0.address) : .network($0) } }
            if remotes.isEmpty { remotes = [.any] }

            for remote in remotes {
                rules.append(make(
                    process, name: name, path: entry.process == "any" ? nil : entry.process, via: via,
                    direction: entry.direction == "incoming" ? .inbound : .outbound,
                    remote: remote, ports: parsePorts(entry.ports),
                    transport: TransportProtocol(rawValue: entry.protocol ?? "any") ?? .any,
                    action: entry.action == "deny" ? .deny : .allow,
                    enabled: !(entry.disabled ?? false), note: entry.notes ?? ""
                ))
            }
        }

        for domain in file.deniedRemoteDomains ?? [] {
            rules.append(make(.any, name: nil, path: nil, remote: .domain(RemoteMatcher.normalize(domain)), action: .deny))
        }
        for host in file.deniedRemoteHosts ?? [] {
            rules.append(make(.any, name: nil, path: nil, remote: .host(RemoteMatcher.normalize(host)), action: .deny))
        }
        for address in file.deniedRemoteAddresses ?? [] {
            guard let network = IPNetwork(address) else { continue }
            rules.append(make(.any, name: nil, path: nil, remote: network.prefixLength == network.address.bitWidth ? .address(network.address) : .network(network), action: .deny))
        }
        return Result(name: file.name, description: file.description, rules: rules, skipped: skipped)
    }

    /// Exports rules Little Snitch can import. Rules for a process need its path, so rules created before Squealer
    /// recorded one are left out; blocklist rules have no equivalent and are skipped.
    public static func export(_ rules: [Rule], name: String, description: String = "") throws -> Data {
        var entries: [Entry] = []
        for rule in rules where rule.origin != .blocklist && rule.lifetime == .forever {
            var entry = Entry()
            switch rule.process {
            case .any: entry.process = "any"
            case .process: guard let path = rule.processPath else { continue }; entry.process = path
            }
            entry.action = rule.action.rawValue
            entry.direction = rule.direction == .inbound ? "incoming" : "outgoing"
            switch rule.remote {
            case .any: entry.remote = "any"
            case .localNetwork: entry.remote = "local-net"
            case .host(let host): entry.remoteHosts = StringList([host])
            case .domain(let domain): entry.remoteDomains = StringList([domain])
            case .address(let address): entry.remoteAddresses = StringList([address.description])
            case .network(let network): entry.remoteAddresses = StringList([network.description])
            case .blocklist: continue
            }
            if rule.ports != .any { entry.ports = formatPorts(rule.ports) }
            if rule.transport != .any { entry.protocol = rule.transport.rawValue }
            if !rule.isEnabled { entry.disabled = true }
            if !rule.note.isEmpty { entry.notes = rule.note }
            entries.append(entry)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(File(name: name, description: description.isEmpty ? nil : description, rules: entries))
    }

    public static func parsePorts(_ text: String?) -> PortMatcher {
        guard let text, !text.isEmpty, text != "any" else { return .any }
        let ranges = text.split(separator: ",").compactMap { part -> PortRange? in
            let bounds = part.split(separator: "-").map { UInt16($0.trimmingCharacters(in: .whitespaces)) }
            switch bounds.count {
            case 1: return bounds[0].map(PortRange.init)
            case 2:
                guard let lower = bounds[0], let upper = bounds[1] else { return nil }
                return PortRange(lower, upper)
            default: return nil
            }
        }
        return ranges.isEmpty ? .any : .ranges(ranges)
    }

    public static func formatPorts(_ ports: PortMatcher) -> String {
        switch ports {
        case .any: ""
        case .ranges(let ranges): ranges.map { $0.lower == $0.upper ? "\($0.lower)" : "\($0.lower)-\($0.upper)" }.joined(separator: ", ")
        }
    }
}
