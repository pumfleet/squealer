import Foundation
import Testing
@testable import SquealerKit

/// Builds a tiny IPv6 MaxMind DB (24-bit records) so the reader can be tested without shipping a real database.
private struct MMDBWriter {
    enum Child { case empty, node(Int), data(Int) }

    var nodes: [[Child]] = [[.empty, .empty]]
    var records: [[UInt8]] = []

    mutating func insert(_ network: IPNetwork, _ record: [String: MMDBReader.Value]) {
        var bits: [Int] = []
        if network.address.isIPv4 { bits = Array(repeating: 0, count: 96) }
        for byte in network.address.bytes {
            for shift in (0..<8).reversed() { bits.append(Int(byte >> UInt8(shift) & 1)) }
        }
        let prefix = (network.address.isIPv4 ? 96 : 0) + network.prefixLength
        records.append(Self.encode(.map(record)))
        let recordIndex = records.count - 1

        var node = 0
        for (index, bit) in bits.prefix(prefix).enumerated() {
            if index == prefix - 1 {
                nodes[node][bit] = .data(recordIndex)
            } else if case .node(let next) = nodes[node][bit] {
                node = next
            } else {
                nodes.append([.empty, .empty])
                nodes[node][bit] = .node(nodes.count - 1)
                node = nodes.count - 1
            }
        }
    }

    func build() -> Data {
        var dataSection: [UInt8] = []
        var offsets: [Int] = []
        for record in records {
            offsets.append(dataSection.count)
            dataSection += record
        }
        var output: [UInt8] = []
        for node in nodes {
            for child in node {
                let value: Int = switch child {
                case .empty: nodes.count
                case .node(let index): index
                case .data(let index): nodes.count + 16 + offsets[index]
                }
                output += [UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
            }
        }
        output += Array(repeating: 0, count: 16)
        output += dataSection
        output += [0xAB, 0xCD, 0xEF] + Array("MaxMind.com".utf8)
        output += Self.encode(.map([
            "node_count": .uint(UInt64(nodes.count)),
            "record_size": .uint(24),
            "ip_version": .uint(6),
            "database_type": .string("Squealer-Test"),
            "build_epoch": .uint(1_700_000_000),
        ]))
        return Data(output)
    }

    static func encode(_ value: MMDBReader.Value) -> [UInt8] {
        func header(_ type: Int, _ size: Int) -> [UInt8] {
            precondition(size < 29)
            return type <= 7 ? [UInt8(type << 5 | size)] : [UInt8(size), UInt8(type - 7)]
        }
        switch value {
        case .string(let string):
            return header(2, string.utf8.count) + Array(string.utf8)
        case .double(let double):
            let bits = double.bitPattern
            let bytes: [UInt8] = (0..<8).map { UInt8(truncatingIfNeeded: bits >> UInt64(56 - $0 * 8)) }
            return header(3, 8) + bytes
        case .uint(let number):
            let all: [UInt8] = (0..<8).map { UInt8(truncatingIfNeeded: number >> UInt64(56 - $0 * 8)) }
            let bytes = Array(all.drop { $0 == 0 })
            return header(9, bytes.count) + bytes
        case .map(let map):
            let entries: [UInt8] = map.sorted { $0.key < $1.key }.flatMap { encode(.string($0.key)) + encode($0.value) }
            return header(7, map.count) + entries
        default:
            fatalError("unsupported in test writer")
        }
    }
}

@Suite struct MMDBTests {
    static let database: Data = {
        var writer = MMDBWriter()
        writer.insert(IPNetwork("8.8.8.0/24")!, [
            "country": .map(["iso_code": .string("US"), "names": .map(["en": .string("United States")])]),
            "city": .map(["names": .map(["en": .string("Mountain View")])]),
            "location": .map(["latitude": .double(37.386), "longitude": .double(-122.0838)]),
        ])
        writer.insert(IPNetwork("2a00:1450::/32")!, [
            "country": .map(["iso_code": .string("IE"), "names": .map(["en": .string("Ireland")])]),
        ])
        return writer.build()
    }()

    @Test func readsMetadata() throws {
        let reader = try MMDBReader(data: Self.database)
        #expect(reader.metadata.recordSize == 24)
        #expect(reader.metadata.ipVersion == 6)
        #expect(reader.metadata.databaseType == "Squealer-Test")
        #expect(reader.metadata.buildEpoch == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func looksUpIPv4ThroughIPv6Tree() throws {
        let reader = try MMDBReader(data: Self.database)
        let record = try #require(try reader.lookup(IPAddress("8.8.8.8")!))
        #expect(record[path: "city", "names", "en"]?.string == "Mountain View")
        #expect(try reader.lookup(IPAddress("8.8.9.1")!) == nil)
    }

    @Test func looksUpIPv6() throws {
        let reader = try MMDBReader(data: Self.database)
        let record = try #require(try reader.lookup(IPAddress("2a00:1450:4009::200e")!))
        #expect(record[path: "country", "iso_code"]?.string == "IE")
    }

    @Test func geoLocationWrapper() throws {
        let geo = GeoIPDatabase(city: try MMDBReader(data: Self.database), asn: nil)
        let location = try #require(geo.location(for: IPAddress("8.8.8.8")!))
        #expect(location.countryCode == "US")
        #expect(location.flag == "🇺🇸")
        #expect(location.placeName == "Mountain View, United States")
        #expect(location.latitude == 37.386)
        #expect(geo.location(for: IPAddress("192.168.1.1")!) == nil)
    }

    @Test func rejectsGarbage() {
        #expect(throws: MMDBReader.ReadError.missingMetadata) {
            try MMDBReader(data: Data(repeating: 1, count: 64))
        }
    }
}

/// Runs against the real DB-IP databases when `scripts/fetch-geoip.sh` has been run.
@Suite struct RealGeoIPTests {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Squealer/Resources/GeoIP")

    static var available: Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("dbip-country-lite.mmdb").path)
    }

    @Test(.enabled(if: available)) func countryAndASNLookups() throws {
        let country = try MMDBReader(contentsOf: Self.directory.appendingPathComponent("dbip-country-lite.mmdb"))
        let asn = try MMDBReader(contentsOf: Self.directory.appendingPathComponent("dbip-asn-lite.mmdb"))
        let geo = GeoIPDatabase(city: country, asn: asn)
        let google = try #require(geo.location(for: IPAddress("8.8.8.8")!))
        #expect(google.countryCode == "US")
        #expect(google.organization?.contains("Google") == true)
        let cloudflareV6 = try #require(geo.location(for: IPAddress("2606:4700:4700::1111")!))
        #expect(cloudflareV6.organization?.localizedCaseInsensitiveContains("cloudflare") == true)
    }
}
