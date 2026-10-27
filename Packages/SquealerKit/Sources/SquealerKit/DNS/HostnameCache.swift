import Foundation
import Synchronization

/// Maps addresses back to the hostnames that resolved to them.
public final class HostnameCache: Sendable {
    private struct Entry {
        var hostname: String
        var expires: Date
    }

    private let entries = Mutex<[IPAddress: Entry]>([:])
    private let capacity: Int
    /// DNS TTLs are often a minute or less, but connections can open long after the lookup, so keep names
    /// around for at least this long.
    private let minimumLifetime: TimeInterval

    public init(capacity: Int = 50_000, minimumLifetime: TimeInterval = 3_600) {
        self.capacity = capacity
        self.minimumLifetime = minimumLifetime
    }

    public func record(_ resolutions: [DNSMessage.Resolution], now: Date = .now) {
        guard !resolutions.isEmpty else { return }
        entries.withLock { entries in
            for resolution in resolutions {
                let lifetime = max(TimeInterval(resolution.ttl), minimumLifetime)
                entries[resolution.address] = Entry(hostname: resolution.hostname, expires: now + lifetime)
            }
            if entries.count > capacity {
                let expired = entries.filter { $0.value.expires <= now }.map(\.key)
                expired.forEach { entries.removeValue(forKey: $0) }
                if entries.count > capacity {
                    let oldest = entries.sorted { $0.value.expires < $1.value.expires }.prefix(entries.count - capacity * 9 / 10)
                    oldest.forEach { entries.removeValue(forKey: $0.key) }
                }
            }
        }
    }

    public func hostname(for address: IPAddress, now: Date = .now) -> String? {
        entries.withLock { entries in
            guard let entry = entries[address], entry.expires > now else { return nil }
            return entry.hostname
        }
    }

    public var count: Int {
        entries.withLock { $0.count }
    }
}
