import Foundation
import Testing
@testable import SquealerKit

@Suite struct BlocklistTests {
    @Test func parsesHostsFiles() throws {
        let text = """
        # StevenBlack style
        127.0.0.1 localhost
        0.0.0.0 0.0.0.0
        0.0.0.0 ads.example.com   # trailing comment
        0.0.0.0 tracker.example.net metrics.example.net
        ::1 ip6-localhost
        not a valid line
        """
        let result = try BlocklistParser.parse(text)
        #expect(result.format == .hosts)
        #expect(result.entries.hosts == ["ads.example.com", "tracker.example.net", "metrics.example.net"])
        #expect(result.entries.matches(hostname: "ads.example.com", address: nil))
        #expect(!result.entries.matches(hostname: "sub.ads.example.com", address: nil))
    }

    @Test func parsesDomainLists() throws {
        let text = """
        # OISD style
        doubleclick.net
        *.googlesyndication.com
        .adnxs.com
        com
        10.0.0.0/8
        203.0.113.7
        """
        let result = try BlocklistParser.parse(text)
        #expect(result.format == .domains)
        #expect(result.entries.domains == ["doubleclick.net", "googlesyndication.com", "adnxs.com"])
        #expect(result.entries.matches(hostname: "a.b.doubleclick.net", address: nil))
        #expect(!result.entries.matches(hostname: "notdoubleclick.net", address: nil))
        #expect(result.entries.matches(hostname: nil, address: IPAddress("10.1.2.3")))
        #expect(result.entries.matches(hostname: nil, address: IPAddress("203.0.113.7")))
        #expect(result.skippedLines == 1)
    }

    @Test func parsesAdblockSubset() throws {
        let text = """
        [Adblock Plus 2.0]
        ! Title: Test
        ||ads.example.com^
        ||tracker.example.org^$important
        ||images.example.com^$image
        @@||allowed.example.com^
        example.com##.banner
        """
        let result = try BlocklistParser.parse(text)
        #expect(result.format == .adblock)
        #expect(result.entries.domains == ["ads.example.com", "tracker.example.org"])
    }

    @Test func parsesLittleSnitchRuleGroups() throws {
        let json = """
        {
          "name": "Trackers",
          "denied-remote-domains": ["tracker.com", "Analytics.Example.com."],
          "denied-remote-hosts": ["pixel.example.net"],
          "denied-remote-addresses": ["198.51.100.0/24", "bogus"]
        }
        """
        let result = try BlocklistParser.parse(json)
        #expect(result.format == .littleSnitch)
        #expect(result.name == "Trackers")
        #expect(result.entries.domains == ["tracker.com", "analytics.example.com"])
        #expect(result.entries.hosts == ["pixel.example.net"])
        #expect(result.entries.networks == [IPNetwork("198.51.100.0/24")!])
        #expect(result.skippedLines == 1)
    }

    @Test func hostnameValidation() {
        #expect(BlocklistParser.isValidHostname("a.example.com"))
        #expect(BlocklistParser.isValidHostname("_dmarc.example.com"))
        #expect(!BlocklistParser.isValidHostname("com"))
        #expect(!BlocklistParser.isValidHostname("-bad.example.com"))
        #expect(!BlocklistParser.isValidHostname("1.2.3.4"))
        #expect(!BlocklistParser.isValidHostname("a..b"))
    }
}

@Suite struct IPAddressTests {
    @Test func parsesAndFormats() {
        #expect(IPAddress("192.168.1.1")?.description == "192.168.1.1")
        #expect(IPAddress("2001:db8::1")?.description == "2001:db8::1")
        #expect(IPAddress("[::1]")?.description == "::1")
        #expect(IPAddress("fe80::1%en0")?.description == "fe80::1")
        #expect(IPAddress("::ffff:10.0.0.1") == IPAddress("10.0.0.1"))
        #expect(IPAddress("example.com") == nil)
    }

    @Test func networkContainment() throws {
        let network = try #require(IPNetwork("10.20.0.0/14"))
        #expect(network.contains(IPAddress("10.23.255.255")!))
        #expect(!network.contains(IPAddress("10.24.0.0")!))
        #expect(network.contains(IPNetwork("10.21.0.0/16")!))
        #expect(!network.contains(IPNetwork("10.0.0.0/8")!))
        let v6 = try #require(IPNetwork("2001:db8::/32"))
        #expect(v6.contains(IPAddress("2001:db8:ffff::1")!))
        #expect(!v6.contains(IPAddress("10.0.0.1")!))
        #expect(IPNetwork("1.2.3.4/33") == nil)
    }

    @Test func reverseNames() {
        #expect(IPAddress("1.2.3.4")?.reverseName == "4.3.2.1.in-addr.arpa")
        #expect(IPAddress("2001:db8::1")?.reverseName.hasSuffix("8.b.d.0.1.0.0.2.ip6.arpa") == true)
    }

    @Test func codableRoundTrip() throws {
        let value = [IPAddress("1.2.3.4")!, IPAddress("::1")!]
        let data = try XPCCoding.encode(value)
        #expect(try XPCCoding.decode([IPAddress].self, from: data) == value)
    }
}
