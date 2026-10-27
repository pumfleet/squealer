import AppKit
import SquealerKit
import SwiftUI
import XCTest
@testable import Squealer

/// Guards against layout regressions that only show up with real-world data, like long host names pushing
/// the alert wider than its panel.
@MainActor
final class LayoutTests: XCTestCase {
    private func alert(host: String, app: String = "Wispr Flow") -> ConnectionAlert {
        let process = ProcessIdentity(path: "/Applications/\(app).app/Contents/MacOS/\(app)", signingID: "com.example.app", teamID: "ABCDE12345", signer: .developerID, bundlePath: "/Applications/\(app).app")
        let flow = FlowContext(process: process, instance: ProcessInstance(pid: 1, generation: 1), direction: .outbound, transport: .udp, remoteAddress: IPAddress("34.160.81.0"), remotePort: 443, remoteHostname: host)
        return ConnectionAlert(flow: flow, attempts: 10, deadline: .distantFuture)
    }

    /// The width the view takes when offered the panel's width, as the panel offers it. Views that can't
    /// shrink (rigid controls, unwrapped text) report more than they were offered.
    private func width(of view: some View) -> CGFloat {
        NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: AlertPanel.width, height: 4_000)).width
    }

    private func width(of alert: ConnectionAlert) -> CGFloat {
        let model = AppModel(backend: DemoBackend(), isDemo: true)
        return width(of: AlertView(alert: alert, position: 0, total: 8, navigate: { _ in }).environment(model))
    }

    func testMeasurementDetectsOverflow() {
        let rigid = HStack { ForEach(0..<6) { Text("segment \($0) label").fixedSize() } }
        XCTAssertGreaterThan(width(of: rigid), AlertPanel.width)
    }

    func testAlertKeepsItsWidthWithLongHostNames() {
        XCTAssertLessThanOrEqual(width(of: alert(host: "o4506267787395072.ingest.us.sentry.io")), AlertPanel.width + 0.5)
        XCTAssertLessThanOrEqual(width(of: alert(host: String(repeating: "verylonglabel.", count: 8) + "example.com")), AlertPanel.width + 0.5)
    }

    func testAlertKeepsItsWidthWithLongAppNames() {
        XCTAssertLessThanOrEqual(width(of: alert(host: "api.example.com", app: "An Application With An Extraordinarily Long Name Indeed")), AlertPanel.width + 0.5)
    }
}

final class TransferTests: XCTestCase {
    func testImportedSquealerRulesNeedApproval() throws {
        let rules = [Rule(process: .any, remote: .domain("example.com"), action: .deny)]
        let data = try RuleTransfer.export(rules)
        let imported = try RuleTransfer.importRules(from: data)
        XCTAssertEqual(imported.rules.count, 1)
        XCTAssertFalse(imported.rules[0].isApproved)
        XCTAssertNotEqual(imported.rules[0].id, rules[0].id)
    }

    func testRejectsUnrelatedFiles() {
        XCTAssertThrowsError(try RuleTransfer.importRules(from: Data("{\"hello\": 1}".utf8)))
    }

    func testBackupDocumentsRoundTrip() throws {
        let backup = ConfigurationBackup(settings: EngineSettings(mode: .silentDeny), rules: [], ruleGroups: [RuleGroup(name: "A")], profiles: [], blocklists: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoded = try XCTUnwrap(BackupDocument.decode(encoder.encode(backup)))
        XCTAssertEqual(decoded.settings.mode, .silentDeny)
        XCTAssertEqual(decoded.ruleGroups.map(\.name), ["A"])
    }
}

@MainActor
final class SearchTests: XCTestCase {
    private func summary(app: String, host: String, port: UInt16 = 443) -> ConnectionSummary {
        let process = ProcessIdentity(path: "/usr/bin/\(app)", signingID: "com.example.\(app)", signer: .developerID, displayName: app)
        return ConnectionSummary(
            id: .init(process: process.key, via: nil, endpoint: EndpointKey(host: host, port: port, transport: .tcp, direction: .outbound)),
            process: process, via: nil, remoteAddress: IPAddress("1.2.3.4"), hostnameSource: .flow,
            lastVerdict: VerdictInfo(action: .allow, kind: .rule)
        )
    }

    func testTokens() {
        let item = summary(app: "curl", host: "api.github.com", port: 8443)
        XCTAssertTrue(SearchQuery("app:curl").matches(item))
        XCTAssertTrue(SearchQuery("host:github").matches(item))
        XCTAssertTrue(SearchQuery("port:8443").matches(item))
        XCTAssertFalse(SearchQuery("port:443").matches(item))
        XCTAssertTrue(SearchQuery("curl github").matches(item))
        XCTAssertFalse(SearchQuery("curl gitlab").matches(item))
    }
}

final class SessionTests: XCTestCase {
    func testSessionIsStableWithinALogin() {
        XCTAssertEqual(Session.current, Session.current)
        XCTAssertLessThan(Session.current.bootTime, .now)
    }
}
