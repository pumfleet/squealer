import Foundation
import Testing
@testable import SquealerKit

@Suite struct LittleSnitchFormatTests {
    let resolve: (String) -> ProcessIdentity? = { path in
        path.contains("Spotify") ? Fixtures.spotify : nil
    }

    @Test func parsesRulesAndDenyLists() throws {
        let json = """
        {
          "name": "Work",
          "rules": [
            {"process": "/Applications/Spotify.app/Contents/MacOS/Spotify", "remote-domains": ["spotify.com", "scdn.co"], "action": "allow", "ports": "443"},
            {"process": "any", "remote": "local-net", "action": "allow", "direction": "incoming"},
            {"process": "/Applications/Missing.app/Contents/MacOS/Missing", "remote": "any", "action": "deny"}
          ],
          "denied-remote-domains": ["tracker.example"]
        }
        """
        let result = try LittleSnitchFormat.parse(Data(json.utf8), origin: .subscription, resolve: resolve)
        #expect(result.name == "Work")
        #expect(result.skipped == ["/Applications/Missing.app/Contents/MacOS/Missing"])
        #expect(result.rules.count == 4)
        #expect(result.rules[0].process == .process(Fixtures.spotify.key))
        #expect(result.rules[0].remote == .domain("spotify.com"))
        #expect(result.rules[0].ports == .port(443))
        #expect(result.rules[2].direction == .inbound && result.rules[2].remote == .localNetwork)
        #expect(result.rules[3].remote == .domain("tracker.example") && result.rules[3].action == .deny)
        #expect(result.rules.allSatisfy { $0.isApproved })
    }

    @Test func importedRulesNeedApproval() throws {
        let json = #"{"rules": [{"process": "any", "remote-hosts": "a.com", "action": "deny"}]}"#
        let result = try LittleSnitchFormat.parse(Data(json.utf8), origin: .imported, resolve: resolve)
        #expect(result.rules.map(\.isApproved) == [false])
    }

    @Test func exportRoundTrips() throws {
        let rules = [
            Rule(process: .process(Fixtures.spotify.key), remote: .domain("spotify.com"), ports: .port(443), action: .allow, processPath: "/Applications/Spotify.app/Contents/MacOS/Spotify"),
            Rule(process: .any, remote: .network(IPNetwork("10.0.0.0/8")!), action: .deny),
        ]
        let data = try LittleSnitchFormat.export(rules, name: "Mine")
        let parsed = try LittleSnitchFormat.parse(data, origin: .imported, resolve: resolve)
        #expect(parsed.name == "Mine")
        #expect(parsed.rules.map(\.remote) == [.domain("spotify.com"), .network(IPNetwork("10.0.0.0/8")!)])
        #expect(parsed.rules[0].ports == .port(443))
    }

    @Test func rejectsOtherJSON() {
        #expect(throws: LittleSnitchFormat.FormatError.self) {
            _ = try LittleSnitchFormat.parse(Data("[1,2]".utf8), origin: .imported, resolve: { _ in nil })
        }
    }
}

@Suite struct KnowledgeBaseTests {
    @Test func identifiesServicesBySuffix() {
        #expect(KnowledgeBase.service(for: "o4506267787395072.ingest.us.sentry.io")?.name == "Sentry")
        #expect(KnowledgeBase.service(for: "o4506267787395072.ingest.us.sentry.io")?.category == .crashReporting)
        #expect(KnowledgeBase.service(for: "www.google-analytics.com")?.category.isTracking == true)
        #expect(KnowledgeBase.service(for: "example.com") == nil)
    }

    @Test func describesSystemProcesses() {
        #expect(KnowledgeBase.processDescription(signingID: "com.apple.trustd") != nil)
        #expect(KnowledgeBase.processDescription(signingID: "com.example.app") == nil)
    }
}

@Suite struct RuleCompatibilityTests {
    @Test func rulesFromOlderVersionsStillDecode() throws {
        struct OldRule: Codable {
            var id = UUID()
            var process = ProcessMatcher.any
            var action = RuleAction.deny
            var remote = RemoteMatcher.domain("a.com")
        }
        let rule = try XPCCoding.decode(Rule.self, from: XPCCoding.encode(OldRule()))
        #expect(rule.isApproved && rule.isEnabled && rule.groupID == nil && rule.lifetime == .forever)
    }

    @Test func disabledGroupsDeactivateTheirRules() {
        let group = UUID()
        var rule = Fixtures.rule(action: .deny)
        rule.groupID = group
        #expect(RuleEngine(rules: [rule], settings: EngineSettings(), disabledGroups: [group]).bestMatch(for: Fixtures.flow()) == nil)
        #expect(RuleEngine(rules: [rule], settings: EngineSettings()).bestMatch(for: Fixtures.flow())?.id == rule.id)
    }
}
