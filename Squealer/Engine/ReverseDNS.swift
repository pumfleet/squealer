import Foundation
import SquealerKit
import SwiftUI

/// PTR lookups for connections that only have an address, done in the app so the extension's hot path never
/// waits on DNS.
actor ReverseDNS {
    static let shared = ReverseDNS()
    private var cache: [IPAddress: String?] = [:]

    func name(for address: IPAddress) async -> String? {
        if let cached = cache[address] { return cached }
        let name = await Task.detached(priority: .utility) { Self.lookup(address) }.value
        cache[address] = name
        return name
    }

    private static func lookup(_ address: IPAddress) -> String? {
        var storage = sockaddr_storage()
        let length: socklen_t
        switch address {
        case .v4:
            var sin = sockaddr_in()
            sin.sin_family = sa_family_t(AF_INET)
            sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            withUnsafeMutableBytes(of: &sin.sin_addr) { $0.copyBytes(from: address.bytes) }
            withUnsafeMutableBytes(of: &storage) { $0.copyBytes(from: withUnsafeBytes(of: sin) { Array($0) }) }
            length = socklen_t(MemoryLayout<sockaddr_in>.size)
        case .v6:
            var sin6 = sockaddr_in6()
            sin6.sin6_family = sa_family_t(AF_INET6)
            sin6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            withUnsafeMutableBytes(of: &sin6.sin6_addr) { $0.copyBytes(from: address.bytes) }
            withUnsafeMutableBytes(of: &storage) { $0.copyBytes(from: withUnsafeBytes(of: sin6) { Array($0) }) }
            length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, length, &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard result == 0 else { return nil }
        return String(decoding: host.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
    }
}

struct ReverseNameLabel: View {
    var address: IPAddress
    @State private var name: String?

    var body: some View {
        Group {
            if let name {
                Label(name, systemImage: "arrow.uturn.backward")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Reverse DNS name for this address. The app connected by address, so this may differ from the name it intended.")
            }
        }
        .task(id: address) { name = await ReverseDNS.shared.name(for: address) }
    }
}
