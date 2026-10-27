import Foundation
import Testing
@testable import SquealerKit

@Suite struct RuleAnalysisTests {
    @Test func detectsDuplicates() {
        let a = Fixtures.rule(remote: .domain("spotify.com"), action: .allow)
        let b = Fixtures.rule(remote: .domain("spotify.com"), action: .allow)
        #expect(RuleAnalysis.issues(for: a, in: [a, b]) == [.duplicate(of: b.id)])
    }

    @Test func allowOverriddenByIdenticalDeny() {
        let allow = Fixtures.rule(remote: .domain("spotify.com"), action: .allow)
        let deny = Fixtures.rule(remote: .domain("spotify.com"), action: .deny)
        #expect(RuleAnalysis.issues(for: allow, in: [allow, deny]) == [.overriddenBy(deny.id)])
        #expect(RuleAnalysis.issues(for: deny, in: [allow, deny]).isEmpty)
    }

    @Test func redundantWhenBroaderRuleAgrees() {
        let broad = Fixtures.rule(remote: .any, action: .allow)
        let narrow = Fixtures.rule(remote: .host("api.spotify.com"), action: .allow)
        #expect(RuleAnalysis.issues(for: narrow, in: [broad, narrow]) == [.redundant(with: broad.id)])
        #expect(RuleAnalysis.issues(for: broad, in: [broad, narrow]).isEmpty)
    }

    @Test func notRedundantWhenCarveOutExists() {
        let broad = Fixtures.rule(remote: .any, action: .allow)
        let carveOut = Fixtures.rule(remote: .domain("spotify.com"), action: .deny)
        let narrow = Fixtures.rule(remote: .host("api.spotify.com"), action: .allow)
        #expect(RuleAnalysis.issues(for: narrow, in: [broad, carveOut, narrow]).isEmpty)
    }

    @Test func remoteCoverage() {
        #expect(RuleAnalysis.covers(.domain("example.com"), .host("a.example.com")))
        #expect(RuleAnalysis.covers(.domain("example.com"), .domain("b.example.com")))
        #expect(!RuleAnalysis.covers(.domain("b.example.com"), .domain("example.com")))
        #expect(RuleAnalysis.covers(.network(IPNetwork("10.0.0.0/8")!), .address(IPAddress("10.1.1.1")!)))
        #expect(RuleAnalysis.covers(.localNetwork, .network(IPNetwork("192.168.4.0/24")!)))
        #expect(!RuleAnalysis.covers(.host("a.com"), .any))
    }
}

@Suite struct RuleBuilderTests {
    @Test func buildsDomainRuleFromAlert() throws {
        let flow = Fixtures.flow(host: "api.spotify.com")
        let rule = try #require(RuleBuilder.rule(for: flow, action: .allow, scope: AlertScope(remote: .domain, ports: .this, duration: .forever)))
        #expect(rule.remote == .domain("spotify.com"))
        #expect(rule.ports == .port(443))
        #expect(rule.process == .process(Fixtures.spotify.key))
        #expect(rule.origin == .alert)
        #expect(RuleEngine(rules: [rule], settings: EngineSettings()).bestMatch(for: flow)?.id == rule.id)
    }

    @Test func fallsBackToAddressWithoutHostname() throws {
        let flow = Fixtures.flow(host: nil)
        let rule = try #require(RuleBuilder.rule(for: flow, action: .deny, scope: AlertScope(remote: .domain)))
        #expect(rule.remote == .address(IPAddress("35.186.224.25")!))
    }

    @Test func localAddressesWidenToLocalNetwork() throws {
        let flow = Fixtures.flow(host: nil, address: "192.168.0.10", direction: .inbound)
        let rule = try #require(RuleBuilder.rule(for: flow, action: .allow, scope: AlertScope(remote: .domain)))
        #expect(rule.remote == .localNetwork)
        #expect(RuleEngine(rules: [rule], settings: EngineSettings()).bestMatch(for: Fixtures.flow(host: nil, address: "192.168.0.187", direction: .inbound))?.id == rule.id)
    }

    @Test func onceProducesNoRule() {
        #expect(RuleBuilder.rule(for: Fixtures.flow(), action: .allow, scope: AlertScope(duration: .once)) == nil)
    }

    @Test func registrableDomains() {
        #expect(DomainName.registrableDomain(of: "a.b.example.com") == "example.com")
        #expect(DomainName.registrableDomain(of: "www.bbc.co.uk") == "bbc.co.uk")
        #expect(DomainName.registrableDomain(of: "example.com") == "example.com")
        #expect(DomainName.registrableDomain(of: "user.github.io") == "user.github.io")
    }

    @Test func describesRules() {
        let rule = Rule(process: .process(Fixtures.spotify.key), remote: .domain("doubleclick.net"), action: .deny, processName: "Spotify")
        #expect(RuleDescription.sentence(for: rule) == "Deny Spotify to connect to *.doubleclick.net")
        let https = Rule(process: .any, remote: .host("example.com"), ports: .port(443), transport: .tcp, action: .allow)
        #expect(RuleDescription.sentence(for: https) == "Allow any process to connect to example.com on port 443 (HTTPS) (TCP)")
        let inbound = Rule(process: .process(Fixtures.spotify.key), direction: .inbound, remote: .localNetwork, action: .allow, processName: "Spotify")
        #expect(RuleDescription.sentence(for: inbound) == "Allow incoming connections to Spotify from the local network")
    }

    @Test func messagesRoundTrip() throws {
        let rule = Fixtures.rule(remote: .network(IPNetwork("10.0.0.0/8")!), ports: .ranges([PortRange(1000, 2000)]), action: .deny, lifetime: .untilQuit(Fixtures.instance))
        let request = EngineRequest.upsertRules([rule])
        let decoded = try XPCCoding.decode(EngineRequest.self, from: XPCCoding.encode(request))
        guard case .upsertRules(let rules) = decoded else { Issue.record("wrong case"); return }
        #expect(rules == [rule])
    }
}

@Suite struct KnownAppsTests {
    @Test func recognisesBrowsersAndTheirHelpers() {
        let chromeHelper = ProcessIdentity(path: "/x", signingID: "com.google.Chrome.helper", teamID: "EQHXZ8M8AV", signer: .developerID)
        #expect(KnownApps.isWebBrowser(chromeHelper))
        #expect(KnownApps.isWebBrowser(Fixtures.safari))
        #expect(KnownApps.isWebBrowser(Fixtures.webkitNetworking))
        #expect(!KnownApps.isWebBrowser(Fixtures.spotify))
        let lookalike = ProcessIdentity(path: "/x", signingID: "com.google.ChromeRemoteDesktop", signer: .developerID)
        #expect(!KnownApps.isWebBrowser(lookalike))
    }
}

@Suite struct DisplayNameTests {
    @Test func versionedExecutablesAreNamedAfterTheirTool() {
        #expect(ProcessIdentity(path: "/Users/me/.local/share/claude/versions/2.1.311", signer: .unsigned).displayName == "claude 2.1.311")
        #expect(ProcessIdentity(path: "/opt/tool/1.4", signer: .unsigned).displayName == "tool 1.4")
        #expect(ProcessIdentity(path: "/usr/local/bin/node", signer: .unsigned).displayName == "node")
        #expect(ProcessIdentity(path: "/Users/me/.local/share/claude/versions/2.1.311", signingID: "com.anthropic.claude-code", signer: .developerID).displayName == "claude-code")
    }
}
