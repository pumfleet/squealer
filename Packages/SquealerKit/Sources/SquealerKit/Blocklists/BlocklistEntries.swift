import Foundation

public struct BlocklistEntries: Hashable, Sendable, Codable {
    /// Matched exactly against the connection's hostname.
    public var hosts: Set<String>
    /// Matched against the hostname and every parent domain.
    public var domains: Set<String>
    public var addresses: Set<IPAddress>
    public var networks: [IPNetwork]

    public init(hosts: Set<String> = [], domains: Set<String> = [], addresses: Set<IPAddress> = [], networks: [IPNetwork] = []) {
        self.hosts = hosts
        self.domains = domains
        self.addresses = addresses
        self.networks = networks
    }

    public var count: Int { hosts.count + domains.count + addresses.count + networks.count }
    public var isEmpty: Bool { count == 0 }

    public func matches(hostname: String?, address: IPAddress?) -> Bool {
        if let hostname {
            if hosts.contains(hostname) { return true }
            if !domains.isEmpty {
                var suffix = Substring(hostname)
                while true {
                    if domains.contains(String(suffix)) { return true }
                    guard let dot = suffix.firstIndex(of: ".") else { break }
                    suffix = suffix[suffix.index(after: dot)...]
                }
            }
        }
        if let address {
            if addresses.contains(address) { return true }
            if networks.contains(where: { $0.contains(address) }) { return true }
        }
        return false
    }
}
