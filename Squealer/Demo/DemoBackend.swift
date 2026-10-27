import Foundation
import SquealerKit
import Synchronization

/// Synthetic traffic for previews, screenshots and UI work without a signed extension. Launch with `-demo`.
final class DemoBackend: EngineBackend, @unchecked Sendable {
    let events: AsyncStream<EngineEvent>
    let connectionChanges: AsyncStream<Bool>
    private let eventContinuation: AsyncStream<EngineEvent>.Continuation
    private let connectionContinuation: AsyncStream<Bool>.Continuation
    private let state = Mutex(State())
    private var timer: Timer?

    private struct State {
        var settings = EngineSettings()
        var rules: [UUID: Rule] = [:]
        var groups: [RuleGroup] = [
            RuleGroup(name: "Developer tools", note: "Package managers and Git hosts"),
            RuleGroup(name: "Privacy essentials", subscription: RuleGroup.Subscription(url: URL(string: "https://example.com/privacy.lsrules")!, lastUpdated: .now - 5_400)),
        ]
        var profiles: [Profile] = [
            Profile(name: "Home", symbol: "house.fill", autoSwitch: .wifi(ssids: ["Pumfleet"])),
            Profile(name: "Café", symbol: "cup.and.saucer.fill"),
        ]
        var blocklists: [BlocklistSubscription] = [
            BlocklistSubscription(name: "HaGeZi Light", url: URL(string: "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/light-onlydomains.txt")!, format: .domains, lastUpdated: .now - 7_200, entryCount: 61_842),
        ]
        var summaries: [ConnectionSummary.ID: ConnectionSummary] = [:]
        var alerts: [ConnectionAlert] = []
        var review: [ReviewItem] = []
        var tick = 0
    }

    private struct DemoApp {
        var identity: ProcessIdentity
        var hosts: [(String, String, UInt16)]
        var weight: Double
    }

    private static func app(_ name: String, _ path: String, id: String, team: String?, signer: Signer, hosts: [(String, String, UInt16)], weight: Double) -> DemoApp {
        DemoApp(
            identity: ProcessIdentity(path: path + "/Contents/MacOS/\(name)", signingID: id, teamID: team, signer: signer, bundleID: id, bundlePath: path, displayName: name),
            hosts: hosts,
            weight: weight
        )
    }

    private static let apps: [DemoApp] = [
        app("Safari", "/Applications/Safari.app", id: "com.apple.Safari", team: nil, signer: .apple, hosts: [
            ("www.apple.com", "17.253.144.10", 443), ("news.ycombinator.com", "209.216.230.207", 443),
            ("en.wikipedia.org", "185.15.59.224", 443), ("www.google-analytics.com", "142.250.180.14", 443),
            ("fonts.gstatic.com", "142.250.187.227", 443),
        ], weight: 3),
        app("Mail", "/System/Applications/Mail.app", id: "com.apple.mail", team: nil, signer: .apple, hosts: [
            ("imap.fastmail.com", "103.168.172.47", 993), ("smtp.fastmail.com", "103.168.172.45", 587),
        ], weight: 0.6),
        app("Music", "/System/Applications/Music.app", id: "com.apple.Music", team: nil, signer: .apple, hosts: [
            ("aod.itunes.apple.com", "17.253.25.201", 443), ("play.itunes.apple.com", "17.154.66.39", 443),
        ], weight: 4),
        app("Slack", "/Applications/Slack.app", id: "com.tinyspeck.slackmacgap", team: "BQR82RBBHL", signer: .developerID, hosts: [
            ("wss-primary.slack.com", "3.120.41.100", 443), ("edgeapi.slack.com", "54.93.112.4", 443),
            ("slack-imgs.com", "151.101.2.49", 443),
        ], weight: 1),
        app("Xcode", "/Applications/Xcode.app", id: "com.apple.dt.Xcode", team: nil, signer: .apple, hosts: [
            ("developerservices2.apple.com", "17.32.194.2", 443), ("github.com", "140.82.121.4", 443),
        ], weight: 0.8),
        app("zoom.us", "/Applications/zoom.us.app", id: "us.zoom.xos", team: "BJ4HAAB9B3", signer: .developerID, hosts: [
            ("zoom.us", "170.114.52.2", 443), ("us05web.zoom.us", "170.114.10.85", 443),
            ("telemetry.zoom.us", "3.235.82.193", 443), ("sg01mmr.zoom.us", "149.137.40.14", 8801),
        ], weight: 5),
        app("Spotify", "/Applications/Spotify.app", id: "com.spotify.client", team: "2FNC3A47ZF", signer: .developerID, hosts: [
            ("api.spotify.com", "35.186.224.25", 443), ("audio-ak-spotify-com.akamaized.net", "23.48.161.210", 443),
            ("pixel.spotify.com", "35.186.224.47", 443), ("ads.doubleclick.net", "142.251.36.6", 443),
        ], weight: 2),
        app("Raycast", "/Applications/Raycast.app", id: "com.raycast.macos", team: "SY64MV22J9", signer: .developerID, hosts: [
            ("backend.raycast.com", "104.18.2.217", 443), ("api.segment.io", "54.230.112.8", 443),
        ], weight: 0.3),
        app("node", "/opt/homebrew/bin", id: "node", team: nil, signer: .adHoc, hosts: [
            ("registry.npmjs.org", "104.16.24.34", 443), ("192.168.1.24", "192.168.1.24", 5432),
        ], weight: 0.5),
    ]

    init() {
        (events, eventContinuation) = AsyncStream.makeStream()
        (connectionChanges, connectionContinuation) = AsyncStream.makeStream()
        seed()
    }

    func connect() {
        connectionContinuation.yield(true)
        DispatchQueue.main.async {
            self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.step() }
        }
    }

    func send(_ request: EngineRequest) async throws -> EngineResponse {
        state.withLock { state -> EngineResponse in
            switch request {
            case .hello:
                return .snapshot(EngineSnapshot(
                    engineVersion: "Demo",
                    settings: state.settings,
                    rules: Array(state.rules.values),
                    ruleGroups: state.groups,
                    profiles: state.profiles,
                    blocklists: state.blocklists,
                    pendingAlerts: state.alerts,
                    connections: Array(state.summaries.values),
                    review: state.review
                ))
            case .setSettings(let settings):
                state.settings = settings
            case .upsertRules(let rules):
                rules.forEach { state.rules[$0.id] = $0 }
            case .deleteRules(let ids):
                ids.forEach { state.rules.removeValue(forKey: $0) }
            case .upsertProfile(let profile):
                state.profiles.removeAll { $0.id == profile.id }
                state.profiles.append(profile)
            case .deleteProfile(let id):
                state.profiles.removeAll { $0.id == id }
            case .upsertBlocklist(var list):
                list.entryCount = list.entryCount == 0 ? Int.random(in: 20_000...150_000) : list.entryCount
                list.lastUpdated = .now
                state.blocklists.removeAll { $0.id == list.id }
                state.blocklists.append(list)
                eventContinuation.yield(.blocklists(state.blocklists))
            case .deleteBlocklist(let id):
                state.blocklists.removeAll { $0.id == id }
            case .resolveAlert(let decision):
                state.alerts.removeAll { $0.id == decision.alertID }
                if case .rule(let rule) = decision.outcome {
                    state.rules[rule.id] = rule
                    eventContinuation.yield(.rules(Array(state.rules.values)))
                }
            case .dismissReview(let ids):
                state.review.removeAll { ids.contains($0.id) }
            case .trafficHistory(let query):
                let step: TimeInterval = query.granularity == .minute ? 60 : 3_600
                var buckets: [TrafficBucket] = []
                var time = query.start
                while time < min(query.end, .now) {
                    let hour = Calendar.current.component(.hour, from: time)
                    let activity = (hour >= 8 && hour <= 23 ? 1.0 : 0.15) * Double.random(in: 0.3...1.4)
                    buckets.append(TrafficBucket(start: time, bytesIn: UInt64(activity * step * 40_000), bytesOut: UInt64(activity * step * 6_000), connections: Int(activity * 20), denied: Int.random(in: 0...2)))
                    time += step
                }
                return .history(buckets)
            case .upsertRuleGroup(let group):
                state.groups.removeAll { $0.id == group.id }
                state.groups.append(group)
            case .deleteRuleGroup(let id, _):
                state.groups.removeAll { $0.id == id }
            case .connectionLog(let query):
                let summaries = state.summaries.values.filter { query.process == nil || $0.process.key == query.process }
                let entries = summaries.prefix(query.limit).enumerated().map { index, summary in
                    ConnectionLogEntry(
                        id: Int64(index), start: summary.lastSeen - Double(index * 37), end: summary.lastSeen - Double(index * 37) + 4,
                        process: summary.process.key, processName: summary.process.displayName,
                        processPath: summary.process.bundlePath ?? summary.process.path, viaName: nil,
                        host: summary.endpoint.host, address: summary.remoteAddress, port: summary.endpoint.port,
                        transport: summary.endpoint.transport, direction: summary.endpoint.direction,
                        verdict: summary.lastVerdict, bytesIn: summary.bytesIn / 20, bytesOut: summary.bytesOut / 20
                    )
                }
                return .log(entries.sorted { $0.start > $1.start })
            case .listBackups, .createBackup:
                return .backups([BackupInfo(id: "auto-1.json", created: .now - 3_600, rules: state.rules.count, isAutomatic: true)])
            case .exportConfiguration:
                return .configuration(ConfigurationBackup(settings: state.settings, rules: Array(state.rules.values), ruleGroups: state.groups, profiles: state.profiles, blocklists: state.blocklists))
            case .refreshBlocklist, .clearHistory, .refreshRuleGroup, .restoreBackup, .restoreConfiguration, .endLogoutSessions:
                break
            }
            return .ok
        }
    }

    private func seed() {
        state.withLock { state in
            for app in Self.apps {
                for (host, address, port) in app.hosts {
                    let summary = makeSummary(app: app, host: host, address: address, port: port, verdict: host.contains("doubleclick") ? VerdictInfo(action: .deny, kind: .rule, ruleID: nil) : VerdictInfo(action: .allow, kind: app.identity.signer == .apple ? .builtin : .rule, builtin: app.identity.signer == .apple ? .applePlatform : nil))
                    state.summaries[summary.id] = summary
                }
            }
            let spotify = Self.apps.first { $0.identity.displayName == "Spotify" }!.identity
            let raycast = Self.apps.first { $0.identity.displayName == "Raycast" }!.identity
            state.rules = Dictionary(uniqueKeysWithValues: [
                Rule(process: .process(spotify.key), remote: .domain("spotify.com"), action: .allow, origin: .alert, processName: "Spotify", processPath: spotify.bundlePath),
                Rule(process: .process(spotify.key), remote: .domain("doubleclick.net"), action: .deny, origin: .alert, processName: "Spotify", processPath: spotify.bundlePath),
                Rule(process: .any, remote: .domain("google-analytics.com"), action: .deny, origin: .user),
                Rule(process: .process(raycast.key), remote: .host("api.segment.io"), action: .deny, origin: .alert, processName: "Raycast", processPath: raycast.bundlePath),
                Rule(process: .process(raycast.key), remote: .any, action: .allow, origin: .alert, processName: "Raycast", processPath: raycast.bundlePath),
            ].map { ($0.id, $0) })
            let node = Self.apps.last!.identity
            state.review = [
                ReviewItem(flow: FlowContext(process: node, instance: ProcessInstance(pid: 4242, generation: 1), direction: .outbound, transport: .tcp, remoteAddress: IPAddress("104.16.24.34"), remotePort: 443, remoteHostname: "registry.npmjs.org"), action: .allow, reason: .silent, attempts: 14),
            ]
        }
    }

    private func makeSummary(app: DemoApp, host: String, address: String, port: UInt16, verdict: VerdictInfo) -> ConnectionSummary {
        let endpoint = EndpointKey(host: host, port: port, transport: port == 8801 ? .udp : .tcp, direction: host.hasPrefix("192.168") ? .inbound : .outbound)
        return ConnectionSummary(
            id: ConnectionSummary.ID(process: app.identity.key, via: nil, endpoint: endpoint),
            process: app.identity,
            via: nil,
            remoteAddress: IPAddress(address),
            hostnameSource: .flow,
            lastVerdict: verdict,
            bytesIn: UInt64.random(in: 50_000...80_000_000),
            bytesOut: UInt64.random(in: 5_000...4_000_000),
            activeFlows: Int.random(in: 0...3),
            totalFlows: Int.random(in: 1...120),
            deniedFlows: verdict.action == .deny ? Int.random(in: 1...30) : 0,
            firstSeen: .now - Double.random(in: 3_600...86_400),
            lastSeen: .now - Double.random(in: 0...3_000)
        )
    }

    private func step() {
        let (update, alert) = state.withLock { state -> (TrafficUpdate, ConnectionAlert?) in
            state.tick += 1
            var changed: [ConnectionSummary] = []
            var totalIn = 0.0
            var totalOut = 0.0
            for (id, var summary) in state.summaries {
                let app = Self.apps.first { $0.identity.key == summary.process.key }
                let active = summary.lastVerdict.action == .allow && Double.random(in: 0...1) < 0.35 * (app?.weight ?? 1) / 2
                let wave = (sin(Double(state.tick) / 6 + Double(abs(id.hashValue % 100))) + 1.2) / 2.2
                summary.rateIn = active ? Double.random(in: 2_000...90_000) * (app?.weight ?? 1) * wave : 0
                summary.rateOut = active ? summary.rateIn * Double.random(in: 0.05...0.3) : 0
                summary.bytesIn += UInt64(summary.rateIn)
                summary.bytesOut += UInt64(summary.rateOut)
                summary.activeFlows = active ? max(1, summary.activeFlows) : 0
                if active { summary.lastSeen = .now }
                totalIn += summary.rateIn
                totalOut += summary.rateOut
                state.summaries[id] = summary
                changed.append(summary)
            }
            var alert: ConnectionAlert?
            if state.tick % 25 == 4, state.alerts.count < 3, state.settings.mode == .alert {
                let candidates: [(String, String, String, UInt16)] = [
                    ("Spotify", "spclient.wg.spotify.com", "35.186.224.24", 443),
                    ("zoom.us", "log-gateway.zoom.us", "3.235.71.21", 443),
                    ("Slack", "slackb.com", "52.28.83.143", 443),
                    ("Raycast", "o4506267787395072.ingest.us.sentry.io", "34.120.195.249", 443),
                ]
                let pick = candidates[(state.tick / 25 + 3) % candidates.count]
                if let app = Self.apps.first(where: { $0.identity.displayName == pick.0 }) {
                    let flow = FlowContext(
                        process: app.identity,
                        instance: ProcessInstance(pid: 812, generation: 3),
                        direction: .outbound,
                        transport: .tcp,
                        remoteAddress: IPAddress(pick.2),
                        remotePort: pick.3,
                        remoteHostname: pick.1,
                        localPort: 61_234,
                        hostnameSource: .flow
                    )
                    let created = ConnectionAlert(flow: flow, attempts: Int.random(in: 1...3), deadline: .distantFuture)
                    state.alerts.append(created)
                    alert = created
                }
            }
            return (TrafficUpdate(timestamp: .now, connections: changed, totalRateIn: totalIn, totalRateOut: totalOut), alert)
        }
        eventContinuation.yield(.traffic(update))
        if let alert {
            eventContinuation.yield(.alert(alert))
        }
    }
}
