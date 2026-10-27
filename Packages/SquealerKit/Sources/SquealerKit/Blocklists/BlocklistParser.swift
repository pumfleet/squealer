import Foundation

public enum BlocklistParser {
    public struct Result: Sendable {
        public var entries: BlocklistEntries
        public var format: BlocklistFormat
        public var name: String?
        public var skippedLines: Int
    }

    public enum ParseError: Error, Equatable {
        case notText
        case invalidLittleSnitchFile
    }

    public static func parse(_ data: Data, format: BlocklistFormat = .automatic) throws -> Result {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ParseError.notText
        }
        return try parse(text, format: format)
    }

    public static func parse(_ text: String, format: BlocklistFormat = .automatic) throws -> Result {
        let resolved = format == .automatic ? detectFormat(text) : format
        if resolved == .littleSnitch {
            return try parseLittleSnitch(text)
        }

        var entries = BlocklistEntries()
        var skipped = 0
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("!") || line.hasPrefix("[") {
                continue
            }
            let accepted = switch resolved {
            case .hosts: parseHostsLine(line, into: &entries)
            case .adblock: parseAdblockLine(line, into: &entries)
            default: parseDomainLine(line, into: &entries)
            }
            if !accepted { skipped += 1 }
        }
        return Result(entries: entries, format: resolved, name: nil, skippedLines: skipped)
    }

    public static func detectFormat(_ text: String) -> BlocklistFormat {
        if text.drop(while: \.isWhitespace).first == "{" {
            return .littleSnitch
        }
        var hostsVotes = 0, adblockVotes = 0, domainVotes = 0
        for line in text.split(whereSeparator: \.isNewline).prefix(500) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("!") || trimmed.hasPrefix("||") || trimmed.hasPrefix("@@") {
                adblockVotes += 1
            } else if let first = trimmed.split(whereSeparator: \.isWhitespace).first,
                      trimmed.contains(where: \.isWhitespace), IPAddress(String(first)) != nil {
                hostsVotes += 1
            } else {
                domainVotes += 1
            }
        }
        if adblockVotes > max(hostsVotes, domainVotes) { return .adblock }
        if hostsVotes > domainVotes { return .hosts }
        return .domains
    }

    private static let hostsIgnored: Set<String> = [
        "localhost", "localhost.localdomain", "local", "broadcasthost", "ip6-localhost", "ip6-loopback",
        "ip6-localnet", "ip6-mcastprefix", "ip6-allnodes", "ip6-allrouters", "ip6-allhosts", "0.0.0.0",
    ]

    private static func stripComment(_ line: String) -> Substring {
        line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
    }

    private static func parseHostsLine(_ line: String, into entries: inout BlocklistEntries) -> Bool {
        let fields = stripComment(line).split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2, IPAddress(String(fields[0])) != nil else {
            return parseDomainLine(line, into: &entries)
        }
        var accepted = false
        for field in fields.dropFirst() {
            let host = RemoteMatcher.normalize(String(field))
            guard !hostsIgnored.contains(host), isValidHostname(host) else { continue }
            entries.hosts.insert(host)
            accepted = true
        }
        return accepted
    }

    private static func parseDomainLine(_ line: String, into entries: inout BlocklistEntries) -> Bool {
        let field = stripComment(line).trimmingCharacters(in: .whitespaces)
        guard !field.isEmpty, !field.contains(where: \.isWhitespace) else { return false }
        if let network = IPNetwork(field) {
            if network.prefixLength == network.address.bitWidth {
                entries.addresses.insert(network.address)
            } else {
                entries.networks.append(network)
            }
            return true
        }
        var name = field
        if name.hasPrefix(".") { name.removeFirst() }
        let domain = RemoteMatcher.normalize(name)
        guard isValidHostname(domain) else { return false }
        entries.domains.insert(domain)
        return true
    }

    private static func parseAdblockLine(_ line: String, into entries: inout BlocklistEntries) -> Bool {
        guard line.hasPrefix("||"), !line.hasPrefix("@@") else { return false }
        var body = line.dropFirst(2)
        if let options = body.firstIndex(of: "$") {
            // Rules with modifiers target specific request types; applying them to whole connections would overblock.
            guard body[body.index(after: options)...].split(separator: ",").allSatisfy({ ["important", "all", "doc", "document"].contains($0) }) else {
                return false
            }
            body = body[..<options]
        }
        guard body.hasSuffix("^") || body.hasSuffix("^|") else { return false }
        while body.hasSuffix("|") || body.hasSuffix("^") { body.removeLast() }
        let domain = RemoteMatcher.normalize(String(body))
        guard isValidHostname(domain) else { return false }
        entries.domains.insert(domain)
        return true
    }

    private struct LittleSnitchFile: Decodable {
        var name: String?
        var deniedRemoteDomains: [String]?
        var deniedRemoteHosts: [String]?
        var deniedRemoteAddresses: [String]?

        enum CodingKeys: String, CodingKey {
            case name
            case deniedRemoteDomains = "denied-remote-domains"
            case deniedRemoteHosts = "denied-remote-hosts"
            case deniedRemoteAddresses = "denied-remote-addresses"
        }
    }

    private static func parseLittleSnitch(_ text: String) throws -> Result {
        guard let file = try? JSONDecoder().decode(LittleSnitchFile.self, from: Data(text.utf8)) else {
            throw ParseError.invalidLittleSnitchFile
        }
        var entries = BlocklistEntries()
        var skipped = 0
        for domain in file.deniedRemoteDomains ?? [] {
            let normalized = RemoteMatcher.normalize(domain)
            if isValidHostname(normalized) { entries.domains.insert(normalized) } else { skipped += 1 }
        }
        for host in file.deniedRemoteHosts ?? [] {
            let normalized = RemoteMatcher.normalize(host)
            if isValidHostname(normalized) { entries.hosts.insert(normalized) } else { skipped += 1 }
        }
        for address in file.deniedRemoteAddresses ?? [] {
            guard let network = IPNetwork(address) else { skipped += 1; continue }
            if network.prefixLength == network.address.bitWidth {
                entries.addresses.insert(network.address)
            } else {
                entries.networks.append(network)
            }
        }
        return Result(entries: entries, format: .littleSnitch, name: file.name, skippedLines: skipped)
    }

    /// Requires at least two labels so a stray `com` can never block an entire TLD.
    public static func isValidHostname(_ name: String) -> Bool {
        guard name.count <= 253, IPAddress(name) == nil else { return false }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }
}
