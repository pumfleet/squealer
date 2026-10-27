import Darwin

public enum IPAddress: Hashable, Sendable, Comparable {
    case v4(UInt32)
    case v6(high: UInt64, low: UInt64)

    public init?(_ string: String) {
        var trimmed = Substring(string)
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
            trimmed = trimmed.dropFirst().dropLast()
        }
        if let zone = trimmed.firstIndex(of: "%") {
            trimmed = trimmed[..<zone]
        }
        let text = String(trimmed)

        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            self = .v4(UInt32(bigEndian: v4.s_addr))
            return
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 {
            self.init(v6Bytes: withUnsafeBytes(of: v6) { Array($0) })
            return
        }
        return nil
    }

    public init?(bytes: some Collection<UInt8>) {
        switch bytes.count {
        case 4:
            self = .v4(bytes.reduce(0) { $0 << 8 | UInt32($1) })
        case 16:
            self.init(v6Bytes: Array(bytes))
        default:
            return nil
        }
    }

    private init(v6Bytes bytes: [UInt8]) {
        let high = bytes[0..<8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let low = bytes[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        if high == 0, low >> 32 == 0xFFFF {
            self = .v4(UInt32(truncatingIfNeeded: low))
        } else {
            self = .v6(high: high, low: low)
        }
    }

    public var isIPv4: Bool {
        if case .v4 = self { return true }
        return false
    }

    public var bytes: [UInt8] {
        switch self {
        case .v4(let value):
            return (0..<4).map { UInt8(truncatingIfNeeded: value >> (24 - $0 * 8)) }
        case .v6(let high, let low):
            return (0..<8).map { UInt8(truncatingIfNeeded: high >> (56 - $0 * 8)) }
                + (0..<8).map { UInt8(truncatingIfNeeded: low >> (56 - $0 * 8)) }
        }
    }

    public var bitWidth: Int { isIPv4 ? 32 : 128 }

    /// Reverse-DNS name (`in-addr.arpa` / `ip6.arpa`) used for PTR lookups.
    public var reverseName: String {
        switch self {
        case .v4:
            return bytes.reversed().map(String.init).joined(separator: ".") + ".in-addr.arpa"
        case .v6:
            let nibbles = bytes.flatMap { [$0 >> 4, $0 & 0xF] }
            return nibbles.reversed().map { String($0, radix: 16) }.joined(separator: ".") + ".ip6.arpa"
        }
    }

    public static func < (lhs: IPAddress, rhs: IPAddress) -> Bool {
        switch (lhs, rhs) {
        case let (.v4(a), .v4(b)): a < b
        case (.v4, .v6): true
        case (.v6, .v4): false
        case let (.v6(ah, al), .v6(bh, bl)): (ah, al) < (bh, bl)
        }
    }
}

extension IPAddress: CustomStringConvertible {
    public var description: String {
        switch self {
        case .v4:
            return bytes.map(String.init).joined(separator: ".")
        case .v6:
            var storage = in6_addr()
            withUnsafeMutableBytes(of: &storage) { $0.copyBytes(from: bytes) }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, &storage, &buffer, socklen_t(buffer.count))
            return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
        }
    }
}

extension IPAddress: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let address = IPAddress(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid IP address \(string)")
        }
        self = address
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public struct IPNetwork: Hashable, Sendable {
    public let address: IPAddress
    public let prefixLength: Int

    public init?(address: IPAddress, prefixLength: Int) {
        guard (0...address.bitWidth).contains(prefixLength) else { return nil }
        self.address = address.masked(to: prefixLength)
        self.prefixLength = prefixLength
    }

    public init?(_ string: String) {
        let parts = string.split(separator: "/", maxSplits: 1)
        guard let address = IPAddress(String(parts[0])) else { return nil }
        if parts.count == 2 {
            guard let length = Int(parts[1]) else { return nil }
            self.init(address: address, prefixLength: length)
        } else {
            self.init(address: address, prefixLength: address.bitWidth)
        }
    }

    public func contains(_ other: IPAddress) -> Bool {
        other.isIPv4 == address.isIPv4 && other.masked(to: prefixLength) == address
    }

    public func contains(_ other: IPNetwork) -> Bool {
        other.prefixLength >= prefixLength && contains(other.address)
    }

    public static let localNetworks: [IPNetwork] = [
        "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "127.0.0.0/8",
        "100.64.0.0/10", "224.0.0.0/4", "255.255.255.255/32",
        "::1/128", "fc00::/7", "fe80::/10", "ff00::/8",
    ].compactMap(IPNetwork.init)
}

extension IPNetwork: CustomStringConvertible {
    public var description: String {
        prefixLength == address.bitWidth ? address.description : "\(address)/\(prefixLength)"
    }
}

extension IPNetwork: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let network = IPNetwork(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid network \(string)")
        }
        self = network
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

extension IPAddress {
    public var isLocal: Bool {
        IPNetwork.localNetworks.contains { $0.contains(self) }
    }

    func masked(to prefixLength: Int) -> IPAddress {
        switch self {
        case .v4(let value):
            let mask: UInt32 = prefixLength == 0 ? 0 : ~UInt32(0) << (32 - prefixLength)
            return .v4(value & mask)
        case .v6(let high, let low):
            let highMask: UInt64 = prefixLength >= 64 ? ~0 : (prefixLength == 0 ? 0 : ~UInt64(0) << (64 - prefixLength))
            let lowBits = max(0, prefixLength - 64)
            let lowMask: UInt64 = lowBits == 0 ? 0 : (lowBits >= 64 ? ~0 : ~UInt64(0) << (64 - lowBits))
            return .v6(high: high & highMask, low: low & lowMask)
        }
    }
}
