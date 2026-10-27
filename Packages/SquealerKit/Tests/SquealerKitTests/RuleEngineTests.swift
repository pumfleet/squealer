import Foundation
import Testing
@testable import SquealerKit

@Suite struct RuleEngineTests {
    let settings = EngineSettings()

    private func decide(_ rules: [Rule], _ flow: FlowContext, settings: EngineSettings? = nil) -> Decision {
        RuleEngine(rules: rules, settings: settings ?? self.settings).decide(flow)
    }

    @Test func asksWhenNothingMatches() {
        #expect(decide([], Fixtures.flow()) == .ask)
    }

    @Test func silentModesDecideUnknownFlows() {
        var settings = settings
        settings.mode = .silentDeny
        #expect(decide([], Fixtures.flow(), settings: settings) == .decided(Verdict(action: .deny, reason: .silentMode)))
        settings.mode = .silentAllow
        #expect(decide([], Fixtures.flow(), settings: settings) == .decided(Verdict(action: .allow, reason: .silentMode)))
    }

    @Test func specificProcessBeatsAnyProcess() {
        let denyAll = Fixtures.rule(nil, remote: .domain("spotify.com"), action: .deny)
        let allowSpotify = Fixtures.rule(remote: .any, action: .allow)
        let engine = RuleEngine(rules: [denyAll, allowSpotify], settings: settings)
        #expect(engine.bestMatch(for: Fixtures.flow())?.id == allowSpotify.id)
    }

    @Test func hostBeatsDomainBeatsAny() {
        let any = Fixtures.rule(remote: .any, action: .deny)
        let domain = Fixtures.rule(remote: .domain("spotify.com"), action: .allow)
        let host = Fixtures.rule(remote: .host("api.spotify.com"), action: .deny)
        let engine = RuleEngine(rules: [any, domain, host], settings: settings)
        #expect(engine.bestMatch(for: Fixtures.flow())?.id == host.id)
        #expect(engine.bestMatch(for: Fixtures.flow(host: "cdn.spotify.com"))?.id == domain.id)
        #expect(engine.bestMatch(for: Fixtures.flow(host: "example.com"))?.id == any.id)
    }

    @Test func longerDomainBeatsShorterDomain() {
        let broad = Fixtures.rule(remote: .domain("spotify.com"), action: .allow)
        let narrow = Fixtures.rule(remote: .domain("ads.spotify.com"), action: .deny)
        let engine = RuleEngine(rules: [broad, narrow], settings: settings)
        #expect(engine.bestMatch(for: Fixtures.flow(host: "x.ads.spotify.com"))?.id == narrow.id)
        #expect(engine.bestMatch(for: Fixtures.flow(host: "notads.spotify.com"))?.id == broad.id)
    }

    @Test func denyWinsAtEqualSpecificity() {
        let allow = Fixtures.rule(remote: .domain("spotify.com"), action: .allow)
        let deny = Fixtures.rule(remote: .domain("spotify.com"), action: .deny)
        #expect(RuleEngine(rules: [allow, deny], settings: settings).bestMatch(for: Fixtures.flow())?.id == deny.id)
        #expect(RuleEngine(rules: [deny, allow], settings: settings).bestMatch(for: Fixtures.flow())?.id == deny.id)
    }

    @Test func specificPortBeatsAnyPort() {
        let anyPort = Fixtures.rule(action: .deny)
        let https = Fixtures.rule(ports: .port(443), action: .allow)
        let engine = RuleEngine(rules: [anyPort, https], settings: settings)
        #expect(engine.bestMatch(for: Fixtures.flow(port: 443))?.id == https.id)
        #expect(engine.bestMatch(for: Fixtures.flow(port: 80))?.id == anyPort.id)
    }

    @Test func addressAndNetworkRules() {
        let network = Fixtures.rule(remote: .network(IPNetwork("35.186.0.0/16")!), action: .deny)
        let address = Fixtures.rule(remote: .address(IPAddress("35.186.224.25")!), action: .allow)
        let engine = RuleEngine(rules: [network, address], settings: settings)
        #expect(engine.bestMatch(for: Fixtures.flow(host: nil))?.id == address.id)
        #expect(engine.bestMatch(for: Fixtures.flow(host: nil, address: "35.186.1.1"))?.id == network.id)
        #expect(engine.bestMatch(for: Fixtures.flow(host: nil, address: "8.8.8.8")) == nil)
    }

    @Test func localNetworkRule() {
        let local = Fixtures.rule(nil, remote: .localNetwork, action: .allow)
        let engine = RuleEngine(rules: [local], settings: settings)
        #expect(engine.bestMatch(for: Fixtures.flow(host: nil, address: "192.168.1.20"))?.id == local.id)
        #expect(engine.bestMatch(for: Fixtures.flow(host: nil, address: "fe80::1"))?.id == local.id)
        #expect(engine.bestMatch(for: Fixtures.flow(host: nil, address: "1.1.1.1")) == nil)
    }

    @Test func directionMustMatch() {
        let inbound = Fixtures.rule(action: .allow, direction: .inbound)
        let engine = RuleEngine(rules: [inbound], settings: settings)
        #expect(engine.bestMatch(for: Fixtures.flow()) == nil)
        #expect(engine.bestMatch(for: Fixtures.flow(direction: .inbound))?.id == inbound.id)
    }

    @Test func inboundFilteringOffAllowsInbound() {
        var settings = settings
        settings.filterInbound = false
        let deny = Fixtures.rule(action: .deny, direction: .any)
        #expect(decide([deny], Fixtures.flow(direction: .inbound), settings: settings)
            == .decided(Verdict(action: .allow, reason: .builtin(.inboundFilteringOff))))
    }

    @Test func expiredAndDisabledRulesAreIgnored() {
        var disabled = Fixtures.rule(action: .deny)
        disabled.isEnabled = false
        let expired = Fixtures.rule(action: .deny, lifetime: .until(.now - 10))
        #expect(decide([disabled, expired], Fixtures.flow()) == .ask)
    }

    @Test func untilQuitRulesOnlyMatchTheirInstance() {
        let rule = Fixtures.rule(action: .allow, lifetime: .untilQuit(Fixtures.instance))
        let engine = RuleEngine(rules: [rule], settings: settings)
        #expect(engine.bestMatch(for: Fixtures.flow())?.id == rule.id)
        #expect(engine.bestMatch(for: Fixtures.flow(instance: ProcessInstance(pid: 100, generation: 2))) == nil)
    }

    @Test func profileScoping() {
        let work = UUID()
        let rule = Fixtures.rule(action: .deny, profileID: work)
        var settings = settings
        #expect(decide([rule], Fixtures.flow(), settings: settings) == .ask)
        settings.activeProfileID = work
        #expect(decide([rule], Fixtures.flow(), settings: settings) == .decided(Verdict(action: .deny, reason: .rule(rule))))
    }

    @Test func applePlatformBinariesAllowedByDefaultButRulesWin() {
        let flow = Fixtures.flow(Fixtures.safari, host: "example.com")
        #expect(decide([], flow) == .decided(Verdict(action: .allow, reason: .builtin(.applePlatform))))
        let deny = Fixtures.rule(Fixtures.safari, action: .deny)
        #expect(decide([deny], flow) == .decided(Verdict(action: .deny, reason: .rule(deny))))
        var settings = settings
        settings.allowApplePlatformBinaries = false
        #expect(decide([], flow, settings: settings) == .ask)
    }

    @Test func viaRules() {
        let flow = Fixtures.flow(Fixtures.safari, via: Fixtures.webkitNetworking, host: "example.com")
        var viaRule = Fixtures.rule(Fixtures.safari, action: .deny)
        viaRule.via = Fixtures.webkitNetworking.key
        let appRule = Fixtures.rule(Fixtures.safari, action: .allow)
        let helperRule = Fixtures.rule(Fixtures.webkitNetworking, action: .allow)

        let engine = RuleEngine(rules: [viaRule, appRule, helperRule], settings: settings)
        #expect(engine.bestMatch(for: flow)?.id == viaRule.id)
        #expect(RuleEngine(rules: [appRule, helperRule], settings: settings).bestMatch(for: flow)?.id == appRule.id)
        #expect(RuleEngine(rules: [helperRule], settings: settings).bestMatch(for: flow)?.id == helperRule.id)
        #expect(engine.bestMatch(for: Fixtures.flow(Fixtures.safari, host: "example.com"))?.id == appRule.id)
    }

    @Test func unsignedProcessesMatchByPath() {
        let rule = Fixtures.rule(Fixtures.unsigned, action: .allow)
        #expect(rule.process == .process(.path("/usr/local/bin/tool")))
        #expect(RuleEngine(rules: [rule], settings: settings).bestMatch(for: Fixtures.flow(Fixtures.unsigned))?.id == rule.id)
    }

    @Test func blocklistsDenyButSpecificRulesOverride() {
        let list = BlocklistSubscription(name: "Ads", url: URL(string: "https://example.com/list")!)
        let entries = BlocklistEntries(domains: ["doubleclick.net"])
        let flow = Fixtures.flow(host: "ad.doubleclick.net")

        let engine = RuleEngine(rules: [], settings: settings, blocklists: [list], blocklistEntries: [list.id: entries])
        #expect(engine.bestMatch(for: flow)?.remote == .blocklist(list.id))
        #expect(engine.bestMatch(for: Fixtures.flow()) == nil)

        let allow = Fixtures.rule(remote: .domain("doubleclick.net"), action: .allow)
        let overridden = RuleEngine(rules: [allow], settings: settings, blocklists: [list], blocklistEntries: [list.id: entries])
        #expect(overridden.bestMatch(for: flow)?.id == allow.id)
    }

    @Test func disabledBlocklistIsIgnored() {
        var list = BlocklistSubscription(name: "Ads", url: URL(string: "https://example.com/list")!)
        list.isEnabled = false
        let engine = RuleEngine(rules: [], settings: settings, blocklists: [list], blocklistEntries: [list.id: BlocklistEntries(domains: ["doubleclick.net"])])
        #expect(engine.bestMatch(for: Fixtures.flow(host: "doubleclick.net")) == nil)
    }

    @Test func squealerAlwaysAllowed() {
        let own = ProcessIdentity(path: "/Applications/Squealer.app/Contents/MacOS/Squealer", signingID: "com.fusial.squealer", teamID: "U6P67B4375", signer: .developerID)
        let deny = Fixtures.rule(nil, action: .deny)
        let engine = RuleEngine(rules: [deny], settings: settings, ownIdentity: OwnIdentity(teamID: "U6P67B4375", signingIDPrefix: "com.fusial.squealer"))
        #expect(engine.decide(Fixtures.flow(own)) == .decided(Verdict(action: .allow, reason: .builtin(.squealer))))
    }

    @Test func hostnamesAreNormalised() {
        let rule = Fixtures.rule(remote: .host("api.spotify.com"), action: .allow)
        let engine = RuleEngine(rules: [rule], settings: settings)
        #expect(engine.bestMatch(for: Fixtures.flow(host: "API.Spotify.com."))?.id == rule.id)
    }
}

@Suite struct SystemServiceTests {
    @Test func dnsOnBehalfOfAppIsAllowed() {
        let mdns = ProcessIdentity(path: "/usr/sbin/mDNSResponder", signingID: "com.apple.mDNSResponder", signer: .apple)
        let flow = Fixtures.flow(Fixtures.spotify, via: mdns, host: nil, address: "1.1.1.1", port: 53, transport: .udp)
        #expect(RuleEngine(rules: [], settings: EngineSettings()).decide(flow) == .decided(Verdict(action: .allow, reason: .builtin(.systemService))))
    }
}

@Suite struct QuietDefaultsTests {
    let engine = RuleEngine(rules: [], settings: EngineSettings())

    @Test func anyAppMayReachAppleServices() {
        #expect(engine.decide(Fixtures.flow(host: "api.apple-cloudkit.com")) == .decided(Verdict(action: .allow, reason: .builtin(.appleServices))))
        #expect(engine.decide(Fixtures.flow(host: "notapple.com")) == .ask)
    }

    @Test func localDiscoveryAndIncomingLocalAreAllowed() {
        let mdns = Fixtures.flow(host: nil, address: "192.168.0.73", port: 5353, transport: .udp, direction: .inbound)
        #expect(engine.decide(mdns) == .decided(Verdict(action: .allow, reason: .builtin(.localDiscovery))))
        let multicast = Fixtures.flow(host: nil, address: "239.255.255.250", port: 1900, transport: .udp)
        #expect(engine.decide(multicast) == .decided(Verdict(action: .allow, reason: .builtin(.localDiscovery))))
        let lanIncoming = Fixtures.flow(host: nil, address: "192.168.0.10", port: 50_000, transport: .tcp, direction: .inbound)
        #expect(engine.decide(lanIncoming) == .decided(Verdict(action: .allow, reason: .builtin(.localIncoming))))
        let lanOutgoing = Fixtures.flow(host: nil, address: "192.168.0.10", port: 5432, transport: .tcp)
        #expect(engine.decide(lanOutgoing) == .ask)
    }

    @Test func unsolicitedInboundUDPIsDeniedWithoutAsking() {
        let flow = Fixtures.flow(host: nil, address: "8.8.4.4", port: 4000, transport: .udp, direction: .inbound)
        #expect(engine.decide(flow) == .decided(Verdict(action: .deny, reason: .builtin(.unsolicitedInbound))))
        let allow = Fixtures.rule(action: .allow, direction: .inbound)
        #expect(RuleEngine(rules: [allow], settings: EngineSettings()).decide(flow) == .decided(Verdict(action: .allow, reason: .rule(allow))))
    }

    @Test func approvedSystemExtensionsAreAllowed() {
        let vpn = ProcessIdentity(
            path: "/Library/SystemExtensions/ABC/io.tailscale.ipn.macsys.network-extension.systemextension/Contents/MacOS/io.tailscale.ipn.macsys.network-extension",
            signingID: "io.tailscale.ipn.macsys.network-extension", teamID: "W5364U7YZB", signer: .developerID
        )
        #expect(engine.decide(Fixtures.flow(vpn, host: nil, address: "199.38.182.118", port: 3478, transport: .udp))
            == .decided(Verdict(action: .allow, reason: .builtin(.systemExtension))))
    }

    @Test func settingsFromOlderVersionsKeepTheirValues() throws {
        struct Old: Codable { var mode = FilterMode.silentAllow; var allowAppStoreApps = true; var historyRetentionDays = 90 }
        let decoded = try XPCCoding.decode(EngineSettings.self, from: XPCCoding.encode(Old()))
        #expect(decoded.mode == .silentAllow)
        #expect(decoded.allowAppStoreApps)
        #expect(decoded.historyRetentionDays == 90)
        #expect(decoded.allowAppleServices)
    }
}
