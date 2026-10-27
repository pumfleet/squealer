import Foundation
import Testing
@testable import SquealerKit

@Suite struct DNSTests {
    /// www.apple.com → CNAME www.apple.com.edgekey.net → CNAME e6858.dscx.akamaiedge.net → A 23.52.10.1, A 23.52.10.2
    static let cnameChainResponse: [UInt8] = {
        var bytes: [UInt8] = [
            0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00,
        ]
        let question = 12
        bytes += encodeName("www.apple.com") + [0x00, 0x01, 0x00, 0x01]

        let edgekeyTarget = encodeName("www.apple.com.edgekey.net")
        bytes += [0xC0, UInt8(question)] + [0x00, 0x05, 0x00, 0x01, 0x00, 0x00, 0x01, 0x2C]
        bytes += [0x00, UInt8(edgekeyTarget.count)]
        let edgekeyOffset = bytes.count
        bytes += edgekeyTarget

        let akamaiTarget = encodeName("e6858.dscx.akamaiedge.net")
        bytes += [0xC0, UInt8(edgekeyOffset)] + [0x00, 0x05, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3C]
        bytes += [0x00, UInt8(akamaiTarget.count)]
        let akamaiOffset = bytes.count
        bytes += akamaiTarget

        for last in [1, 2] as [UInt8] {
            bytes += [0xC0, UInt8(akamaiOffset)] + [0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x14, 0x00, 0x04]
            bytes += [23, 52, 10, last]
        }
        return bytes
    }()

    static func encodeName(_ name: String) -> [UInt8] {
        name.split(separator: ".").flatMap { [UInt8($0.utf8.count)] + Array($0.utf8) } + [0]
    }

    @Test func parsesCNAMEChainBackToQuestion() throws {
        let message = try DNSMessage(Self.cnameChainResponse)
        #expect(message.isResponse)
        #expect(message.questions.first?.name == "www.apple.com")
        #expect(message.answers.count == 4)
        let resolutions = message.resolutions
        #expect(resolutions.map(\.address) == [IPAddress("23.52.10.1")!, IPAddress("23.52.10.2")!])
        #expect(resolutions.allSatisfy { $0.hostname == "www.apple.com" })
        #expect(resolutions.first?.ttl == 20)
    }

    @Test func parsesAAAA() throws {
        var bytes: [UInt8] = [0x00, 0x01, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]
        bytes += Self.encodeName("example.com") + [0x00, 0x1C, 0x00, 0x01]
        bytes += [0xC0, 0x0C, 0x00, 0x1C, 0x00, 0x01, 0x00, 0x00, 0x0E, 0x10, 0x00, 0x10]
        bytes += IPAddress("2606:2800:220:1:248:1893:25c8:1946")!.bytes
        let resolutions = try DNSMessage(bytes).resolutions
        #expect(resolutions == [DNSMessage.Resolution(address: IPAddress("2606:2800:220:1:248:1893:25c8:1946")!, hostname: "example.com", ttl: 3600)])
    }

    @Test func rejectsTruncatedMessages() {
        #expect(throws: DNSMessage.ParseError.self) {
            try DNSMessage(Self.cnameChainResponse.dropLast(3))
        }
    }

    @Test func rejectsPointerLoops() {
        var bytes: [UInt8] = [0x00, 0x01, 0x81, 0x80, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        bytes += [0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01]
        #expect(throws: DNSMessage.ParseError.badPointer) {
            try DNSMessage(bytes)
        }
    }

    @Test func queriesAndErrorsYieldNoResolutions() throws {
        var query = Self.cnameChainResponse
        query[2] = 0x01
        #expect(try DNSMessage(query).resolutions.isEmpty)
        var nxdomain = Self.cnameChainResponse
        nxdomain[3] = 0x83
        #expect(try DNSMessage(nxdomain).resolutions.isEmpty)
    }

    @Test func streamBufferReassemblesTCPMessages() {
        let message = Self.cnameChainResponse
        let framed = [UInt8(message.count >> 8), UInt8(message.count & 0xFF)] + message
        var buffer = DNSStreamBuffer()
        #expect(buffer.append(framed.prefix(10)).isEmpty)
        let parsed = buffer.append(framed.dropFirst(10) + framed)
        #expect(parsed.count == 2)
    }

    @Test func hostnameCacheExpiresAndEvicts() {
        let cache = HostnameCache(capacity: 10, minimumLifetime: 60)
        let now = Date()
        cache.record([DNSMessage.Resolution(address: IPAddress("1.2.3.4")!, hostname: "a.com", ttl: 5)], now: now)
        #expect(cache.hostname(for: IPAddress("1.2.3.4")!, now: now + 30) == "a.com")
        #expect(cache.hostname(for: IPAddress("1.2.3.4")!, now: now + 61) == nil)

        let many = (0..<20).map { DNSMessage.Resolution(address: .v4(UInt32($0)), hostname: "h\($0).com", ttl: UInt32($0)) }
        cache.record(many, now: now)
        #expect(cache.count <= 10)
    }
}
