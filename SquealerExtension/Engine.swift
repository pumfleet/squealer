import Foundation
@preconcurrency import NetworkExtension
import Network
import os
import SquealerKit
import Synchronization

let log = Logger(subsystem: XPCConstants.logSubsystem, category: "engine")

/// The extension's single source of truth: configuration, the compiled rule snapshot, paused flows and
/// traffic statistics. Hot-path reads (`handleNewFlow`) only touch lock-protected snapshots; every mutation
/// runs on `queue`.
final class Engine: Sendable {
    static let shared = Engine()

    private struct Configuration {
        var settings = EngineSettings()
        var rules: [UUID: Rule] = [:]
        var ruleGroups: [UUID: RuleGroup] = [:]
        var profiles: [Profile] = []
        var blocklists: [UUID: BlocklistSubscription] = [:]
        var blocklistEntries: [UUID: BlocklistEntries] = [:]
        var review: [ConnectionSummary.ID: ReviewItem] = [:]
        var reviewChanged = false
    }

    final class ProviderBox: @unchecked Sendable {
        weak var provider: NEFilterDataProvider?
    }

    let queue = DispatchQueue(label: "com.fusial.squealer.engine")
    let version: String
    private let configuration = Mutex(Configuration())
    private let snapshot = Mutex(RuleEngine(rules: [], settings: EngineSettings()))
    private let providerBox = ProviderBox()
    private let dnsStreams = Mutex<[UUID: DNSStreamBuffer]>([:])
    private let timers = Mutex<[DispatchSourceTimer]>([])

    let store: Store?
    let resolver = ProcessResolver()
    let hostnames = HostnameCache()
    let traffic = TrafficAggregator()
    let blocklistUpdater = BlocklistUpdater()
    private let backups = Mutex<BackupManager?>(nil)
    private(set) nonisolated(unsafe) var coordinator: FlowCoordinator!
    private(set) nonisolated(unsafe) var server: XPCServer!

    private static let ownIdentity = OwnIdentity(teamID: XPCConstants.teamID, signingIDPrefix: XPCConstants.appBundleID)
    private static let maximumReviewItems = 1_000

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        version = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
        do {
            store = try Store()
        } catch {
            log.fault("Couldn't open store: \(error.localizedDescription, privacy: .public)")
            store = nil
        }
        coordinator = FlowCoordinator(engine: self)
        server = XPCServer(engine: self)
        if let store {
            backups.withLock { $0 = BackupManager(directory: store.backupDirectory) }
        }
    }

    func start() {
        queue.sync {
            loadConfiguration()
            rebuild()
        }
        server.start()
        schedule(every: 1) { [weak self] in self?.tick() }
        schedule(every: 60) { [weak self] in self?.maintenance() }
        schedule(every: 3_600) { [weak self] in
            self?.refreshStaleBlocklists()
            self?.refreshStaleRuleGroups()
        }
        refreshStaleBlocklists()
        refreshStaleRuleGroups()
        log.info("Engine \(self.version, privacy: .public) started")
    }

    var currentRules: RuleEngine {
        snapshot.withLock { $0 }
    }

    // MARK: Provider

    func attach(_ provider: NEFilterDataProvider) {
        providerBox.provider = provider
    }

    func detach() {
        coordinator.releaseAll(action: .allow, reason: .noClient)
        providerBox.provider = nil
    }

    func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        guard let socketFlow = flow as? NEFilterSocketFlow, let context = makeContext(socketFlow) else {
            return .allow()
        }
        let rules = currentRules
        let observeDNS = rules.settings.observeDNS && isDNS(context)

        switch rules.decide(context) {
        case .decided(let verdict):
            record(context, verdict: verdict)
            if case .builtin(.unsolicitedInbound) = verdict.reason {
                addReview(context, action: .deny, reason: .builtin, attempts: 1)
            }
            if verdict.action == .allow, observeDNS {
                let dataVerdict = NEFilterNewFlowVerdict.filterDataVerdict(
                    withFilterInbound: true, peekInboundBytes: 65_535, filterOutbound: false, peekOutboundBytes: 0
                )
                dataVerdict.statisticsReportFrequency = .medium
                return dataVerdict
            }
            return Self.verdict(for: verdict.action)
        case .ask:
            guard server.hasClients else {
                let action: RuleAction = rules.settings.noClientAction == .allow ? .allow : .deny
                let verdict = Verdict(action: action, reason: .noClient)
                record(context, verdict: verdict)
                addReview(context, action: action, reason: .noClient, attempts: 1)
                return Self.verdict(for: action)
            }
            traffic.recordNewFlow(id: context.id, context: context, verdict: VerdictInfo(action: .allow, kind: .pending))
            coordinator.enqueue(FlowBox(flow, context: context), timeout: rules.settings.alertTimeout)
            return .pause()
        }
    }

    func resume(_ box: FlowBox, verdict: Verdict) {
        record(box.context, verdict: verdict)
        if case .silentMode = verdict.reason {
            addReview(box.context, action: verdict.action, reason: .silent, attempts: 1)
        }
        providerBox.provider?.resumeFlow(box.flow, with: Self.verdict(for: verdict.action))
    }

    func handleInboundData(from flow: NEFilterFlow, bytes: Data) -> NEFilterDataVerdict {
        guard let socketFlow = flow as? NEFilterSocketFlow else { return .allow() }
        if socketFlow.socketProtocol == IPPROTO_TCP {
            let messages = dnsStreams.withLock { streams in
                var buffer = streams[flow.identifier] ?? DNSStreamBuffer()
                let messages = buffer.append(bytes)
                streams[flow.identifier] = buffer
                return messages
            }
            messages.forEach { hostnames.record($0.resolutions) }
        } else if let message = try? DNSMessage(bytes) {
            hostnames.record(message.resolutions)
        }
        return NEFilterDataVerdict(passBytes: bytes.count, peekBytes: 65_535)
    }

    func handle(_ report: NEFilterReport) {
        guard let flowID = report.flow?.identifier else { return }
        switch report.event {
        case .statistics:
            traffic.recordBytes(flowID: flowID, inbound: UInt64(report.bytesInboundCount), outbound: UInt64(report.bytesOutboundCount), closed: false)
        case .flowClosed:
            traffic.recordBytes(flowID: flowID, inbound: UInt64(report.bytesInboundCount), outbound: UInt64(report.bytesOutboundCount), closed: true)
            dnsStreams.withLock { _ = $0.removeValue(forKey: flowID) }
        default:
            break
        }
    }

    private static func verdict(for action: RuleAction) -> NEFilterNewFlowVerdict {
        guard action == .allow else { return .drop() }
        let verdict = NEFilterNewFlowVerdict.allow()
        verdict.statisticsReportFrequency = .medium
        return verdict
    }

    private func record(_ context: FlowContext, verdict: Verdict) {
        if !(verdict.action == .allow && isDelegatedLookup(context)) {
            traffic.recordNewFlow(id: context.id, context: context, verdict: VerdictInfo(verdict))
        }
        if verdict.action == .deny {
            log.info("Denied \(context.process.displayName, privacy: .public) → \(context.remoteDisplayName, privacy: .public):\(context.remotePort)")
        }
    }

    /// Any plain DNS lookup, whether made by mDNSResponder or by an app with its own resolver.
    private func isDNS(_ context: FlowContext) -> Bool {
        context.direction == .outbound && context.remotePort == 53
    }

    /// Lookups mDNSResponder makes on an app's behalf would otherwise add a port-53 row for every host the app
    /// talks to; the connection that follows is what matters.
    private func isDelegatedLookup(_ context: FlowContext) -> Bool {
        isDNS(context) && context.via?.signingID == "com.apple.mDNSResponder"
    }

    private func makeContext(_ flow: NEFilterSocketFlow) -> FlowContext? {
        let processToken = flow.sourceProcessAuditToken ?? flow.sourceAppAuditToken
        guard let processToken, let process = resolver.resolve(auditToken: processToken) else { return nil }
        var app = process
        if let appToken = flow.sourceAppAuditToken, appToken != processToken, let resolved = resolver.resolve(auditToken: appToken) {
            app = resolved
        }
        let primary = resolver.parentApp(of: app.identity) ?? app.identity
        let via = primary.key == process.identity.key ? nil : process.identity

        var address: SquealerKit.IPAddress?
        var port: UInt16 = 0
        var endpointName: String?
        if case .hostPort(let host, let remotePort)? = flow.remoteFlowEndpoint {
            port = remotePort.rawValue
            switch host {
            case .ipv4(let ipv4): address = SquealerKit.IPAddress(bytes: ipv4.rawValue)
            case .ipv6(let ipv6): address = SquealerKit.IPAddress(bytes: ipv6.rawValue)
            case .name(let name, _): endpointName = name
            @unknown default: break
            }
        }
        var localPort: UInt16 = 0
        if case .hostPort(_, let local)? = flow.localFlowEndpoint {
            localPort = local.rawValue
        }

        var hostname: String?
        var source = HostnameSource.none
        if let name = flow.remoteHostname ?? flow.url?.host ?? endpointName, SquealerKit.IPAddress(name) == nil {
            hostname = name
            source = .flow
        } else if let address, let cached = hostnames.hostname(for: address) {
            hostname = cached
            source = .dns
        }

        return FlowContext(
            id: flow.identifier,
            process: primary,
            instance: app.instance,
            via: via,
            direction: flow.direction == .inbound ? .inbound : .outbound,
            transport: flow.socketProtocol == IPPROTO_TCP ? .tcp : flow.socketProtocol == IPPROTO_UDP ? .udp : .any,
            remoteAddress: address,
            remotePort: port,
            remoteHostname: hostname,
            localPort: localPort,
            hostnameSource: source
        )
    }

    // MARK: Requests

    func handle(_ request: EngineRequest) async -> EngineResponse {
        if case .trafficHistory(let query) = request {
            return await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    flushHistory()
                    do {
                        continuation.resume(returning: .history(try store?.trafficHistory(query) ?? []))
                    } catch {
                        continuation.resume(returning: .failure(error.localizedDescription))
                    }
                }
            }
        }
        if case .refreshBlocklist(let id) = request {
            return await refreshBlocklist(id)
        }
        if case .refreshRuleGroup(let id) = request {
            return await refreshRuleGroup(id)
        }
        if case .connectionLog(let query) = request {
            return await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    flushLog()
                    do {
                        continuation.resume(returning: .log(try store?.connectionLog(query) ?? []))
                    } catch {
                        continuation.resume(returning: .failure(error.localizedDescription))
                    }
                }
            }
        }
        return queue.sync { handleOnQueue(request) }
    }

    private func handleOnQueue(_ request: EngineRequest) -> EngineResponse {
        do {
            switch request {
            case .hello:
                return .snapshot(makeSnapshot())

            case .setSettings(let settings):
                log.info("Settings changed: mode \(settings.mode.rawValue, privacy: .public), profile \(settings.activeProfileID?.uuidString ?? "default", privacy: .public)")
                configuration.withLock { $0.settings = settings }
                try store?.setSetting(settings, key: "settings")
                rebuild()
                broadcast(.settings(settings))

            case .upsertRules(let rules):
                let now = Date()
                let saved = configuration.withLock { configuration in
                    rules.map { rule in
                        var rule = rule
                        if case .host(let host) = rule.remote { rule.remote = .host(RemoteMatcher.normalize(host)) }
                        if case .domain(let domain) = rule.remote { rule.remote = .domain(RemoteMatcher.normalize(domain)) }
                        rule.modifiedAt = now
                        configuration.rules[rule.id] = rule
                        return rule
                    }
                }
                try store?.save(saved.map { ($0.id, $0) }, table: "rule")
                rebuild()
                broadcastRules()

            case .deleteRules(let ids):
                configuration.withLock { configuration in ids.forEach { configuration.rules.removeValue(forKey: $0) } }
                try store?.delete(ids, table: "rule")
                rebuild()
                broadcastRules()

            case .upsertProfile(let profile):
                let profiles = configuration.withLock { configuration in
                    if let index = configuration.profiles.firstIndex(where: { $0.id == profile.id }) {
                        configuration.profiles[index] = profile
                    } else {
                        configuration.profiles.append(profile)
                    }
                    return configuration.profiles
                }
                try store?.save([(profile.id, profile)], table: "profile")
                broadcast(.profiles(profiles))

            case .deleteProfile(let id):
                let (profiles, removedRules, settings) = configuration.withLock { configuration in
                    configuration.profiles.removeAll { $0.id == id }
                    let removed = configuration.rules.values.filter { $0.profileID == id }.map(\.id)
                    removed.forEach { configuration.rules.removeValue(forKey: $0) }
                    if configuration.settings.activeProfileID == id {
                        configuration.settings.activeProfileID = nil
                    }
                    return (configuration.profiles, removed, configuration.settings)
                }
                try store?.delete([id], table: "profile")
                try store?.delete(removedRules, table: "rule")
                try store?.setSetting(settings, key: "settings")
                rebuild()
                broadcast(.profiles(profiles))
                broadcast(.settings(settings))
                broadcastRules()

            case .upsertBlocklist(let subscription):
                let isNew = configuration.withLock { configuration in
                    defer { configuration.blocklists[subscription.id] = subscription }
                    return configuration.blocklists[subscription.id]?.url != subscription.url
                        || configuration.blocklists[subscription.id]?.format != subscription.format
                }
                try store?.save([(subscription.id, subscription)], table: "blocklist")
                rebuild()
                broadcastBlocklists()
                if isNew {
                    Task { _ = await refreshBlocklist(subscription.id) }
                }

            case .deleteBlocklist(let id):
                configuration.withLock { configuration in
                    configuration.blocklists.removeValue(forKey: id)
                    configuration.blocklistEntries.removeValue(forKey: id)
                }
                try store?.delete([id], table: "blocklist")
                if let store { blocklistUpdater.removeCache(id: id, in: store.blocklistDirectory) }
                rebuild()
                broadcastBlocklists()

            case .resolveAlert(let decision):
                resolveAlert(decision)

            case .dismissReview(let ids):
                let ids = Set(ids)
                configuration.withLock { configuration in
                    configuration.review = configuration.review.filter { !ids.contains($0.value.id) }
                    configuration.reviewChanged = true
                }

            case .clearHistory:
                traffic.clear()
                _ = traffic.drainLog()
                try store?.clearTraffic()
                try store?.clearLog()

            case .upsertRuleGroup(let group):
                let previous = configuration.withLock { configuration in
                    defer { configuration.ruleGroups[group.id] = group }
                    return configuration.ruleGroups[group.id]
                }
                try store?.save([(group.id, group)], table: "rule_group")
                rebuild()
                broadcastRuleGroups()
                if let url = group.subscription?.url, previous?.subscription?.url != url {
                    Task { _ = await refreshRuleGroup(group.id) }
                }

            case .deleteRuleGroup(let id, let deleteRules):
                let (removed, ungrouped) = configuration.withLock { configuration in
                    configuration.ruleGroups.removeValue(forKey: id)
                    let members = configuration.rules.values.filter { $0.groupID == id }
                    var ungrouped: [Rule] = []
                    for var rule in members {
                        if deleteRules {
                            configuration.rules.removeValue(forKey: rule.id)
                        } else {
                            rule.groupID = nil
                            configuration.rules[rule.id] = rule
                            ungrouped.append(rule)
                        }
                    }
                    return (deleteRules ? members.map(\.id) : [], ungrouped)
                }
                try store?.delete([id], table: "rule_group")
                try store?.delete(removed, table: "rule")
                try store?.save(ungrouped.map { ($0.id, $0) }, table: "rule")
                rebuild()
                broadcastRuleGroups()
                broadcastRules()

            case .listBackups:
                return .backups(backups.withLock { $0?.list() ?? [] })

            case .createBackup:
                try makeBackup(automatic: false)
                return .backups(backups.withLock { $0?.list() ?? [] })

            case .restoreBackup(let id):
                guard let backup = try backups.withLock({ try $0?.load(id) }) else { return .failure("Backup not found") }
                try restore(backup)

            case .restoreConfiguration(let backup):
                try restore(backup)

            case .exportConfiguration:
                return .configuration(currentConfiguration())

            case .endLogoutSessions(let session):
                let ended = configuration.withLock { configuration in
                    let ended = configuration.rules.values.filter { rule in
                        if case .untilLogout(let other) = rule.lifetime { return other != session }
                        return false
                    }.map(\.id)
                    ended.forEach { configuration.rules.removeValue(forKey: $0) }
                    return ended
                }
                if !ended.isEmpty {
                    try store?.delete(ended, table: "rule")
                    rebuild()
                    broadcastRules()
                }

            case .eraseAllData:
                try store?.erase()

            case .trafficHistory, .refreshBlocklist, .refreshRuleGroup, .connectionLog:
                break
            }
            return .ok
        } catch {
            log.error("Request failed: \(error.localizedDescription, privacy: .public)")
            return .failure(error.localizedDescription)
        }
    }

    private func resolveAlert(_ decision: AlertDecision) {
        switch decision.outcome {
        case .once(let action):
            coordinator.resolve(alertID: decision.alertID, with: .verdict(Verdict(action: action, reason: .userOnce)))
        case .later:
            coordinator.resolve(alertID: decision.alertID, with: .later)
        case .rule(var rule):
            rule.modifiedAt = .now
            configuration.withLock { $0.rules[rule.id] = rule }
            try? store?.save([(rule.id, rule)], table: "rule")
            rebuild()
            broadcastRules()
            // The rule normally resolves the alert during rebuild; if it doesn't cover it (e.g. it targets a
            // different profile), apply the user's choice to the waiting connection anyway.
            coordinator.resolve(alertID: decision.alertID, with: .verdict(Verdict(action: rule.action, reason: .rule(rule))))
        }
    }

    // MARK: State

    private func loadConfiguration() {
        guard let store else { return }
        var rules = (try? store.loadAll(Rule.self, table: "rule")) ?? []
        let ruleGroups = (try? store.loadAll(RuleGroup.self, table: "rule_group")) ?? []
        let migrated = migratePathRules(&rules)
        if !migrated.isEmpty {
            try? store.save(migrated.map { ($0.id, $0) }, table: "rule")
            log.info("Moved \(migrated.count) rules from file paths to code signatures")
        }
        let profiles = (try? store.loadAll(Profile.self, table: "profile")) ?? []
        let blocklists = (try? store.loadAll(BlocklistSubscription.self, table: "blocklist")) ?? []
        let settings = store.setting(EngineSettings.self, key: "settings") ?? EngineSettings()
        let review = store.setting([ReviewItem].self, key: "review") ?? []

        // "Until quit" rules can't outlive a restart of the extension (their process instances are gone), and
        // "until restart" rules end when the Mac boots again.
        let bootTime = Self.bootTime
        let (live, stale) = rules.reduce(into: ([Rule](), [UUID]())) { result, rule in
            switch rule.lifetime {
            case .untilQuit(let instance) where !ProcessResolver.isAlive(instance):
                result.1.append(rule.id)
            case .untilRestart(let boot) where abs(boot.timeIntervalSince(bootTime)) > 2:
                result.1.append(rule.id)
            default:
                result.0.append(rule)
            }
        }
        try? store.delete(stale, table: "rule")

        var entries: [UUID: BlocklistEntries] = [:]
        for subscription in blocklists {
            entries[subscription.id] = blocklistUpdater.loadCached(subscription, from: store.blocklistDirectory)
        }

        configuration.withLock { configuration in
            configuration.settings = settings
            configuration.rules = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
            configuration.ruleGroups = Dictionary(uniqueKeysWithValues: ruleGroups.map { ($0.id, $0) })
            configuration.profiles = profiles
            configuration.blocklists = Dictionary(uniqueKeysWithValues: blocklists.map { ($0.id, $0) })
            configuration.blocklistEntries = entries
            configuration.review = Dictionary(review.map { ($0.groupKey, $0) }, uniquingKeysWith: { a, _ in a })
        }
        log.info("Loaded \(live.count) rules, \(profiles.count) profiles, \(blocklists.count) blocklists")
    }

    private func rebuild() {
        let engine = configuration.withLock { configuration in
            RuleEngine(
                rules: Array(configuration.rules.values),
                settings: configuration.settings,
                disabledGroups: Set(configuration.ruleGroups.values.filter { !$0.isEnabled }.map(\.id)),
                blocklists: Array(configuration.blocklists.values),
                blocklistEntries: configuration.blocklistEntries,
                ownIdentity: Self.ownIdentity
            )
        }
        snapshot.withLock { $0 = engine }
        coordinator.reevaluate()
    }

    private func makeSnapshot() -> EngineSnapshot {
        let configuration = configuration.withLock { configuration in
            (configuration.settings, Array(configuration.rules.values), configuration.profiles, Array(configuration.blocklists.values), Array(configuration.review.values), Array(configuration.ruleGroups.values))
        }
        return EngineSnapshot(
            engineVersion: version,
            settings: configuration.0,
            rules: configuration.1,
            ruleGroups: configuration.5,
            profiles: configuration.2,
            blocklists: configuration.3,
            pendingAlerts: coordinator.pendingAlerts,
            connections: traffic.allSummaries(),
            review: configuration.4.sorted { $0.lastSeen > $1.lastSeen }
        )
    }

    func addReview(_ context: FlowContext, action: RuleAction, reason: VerdictInfo.Kind, attempts: Int) {
        configuration.withLock { configuration in
            let key = ConnectionSummary.ID(process: context.process.key, via: context.via?.key, endpoint: context.endpointKey)
            if var item = configuration.review[key] {
                item.attempts += attempts
                item.lastSeen = .now
                item.action = action
                item.reason = reason
                configuration.review[key] = item
            } else {
                configuration.review[key] = ReviewItem(flow: context, action: action, reason: reason, attempts: attempts)
                if configuration.review.count > Self.maximumReviewItems,
                   let oldest = configuration.review.min(by: { $0.value.lastSeen < $1.value.lastSeen })?.key {
                    configuration.review.removeValue(forKey: oldest)
                }
            }
            configuration.reviewChanged = true
        }
    }

    // MARK: Clients

    func broadcast(_ event: EngineEvent) {
        server.broadcast(event)
    }

    private func broadcastRules() {
        broadcast(.rules(configuration.withLock { Array($0.rules.values) }))
    }

    private func broadcastBlocklists() {
        broadcast(.blocklists(configuration.withLock { Array($0.blocklists.values) }))
    }

    private func broadcastRuleGroups() {
        broadcast(.ruleGroups(configuration.withLock { Array($0.ruleGroups.values) }))
    }

    func clientsDidDisconnect() {
        let action: RuleAction = currentRules.settings.noClientAction == .allow ? .allow : .deny
        coordinator.releaseAll(action: action, reason: .noClient)
    }

    // MARK: Timers

    private func schedule(every interval: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 100)))
        timer.setEventHandler(handler: work)
        timer.resume()
        timers.withLock { $0.append(timer) }
    }

    private func tick() {
        let update = traffic.tick()
        guard server.hasClients else { return }
        if let update, !update.connections.isEmpty || update.totalRateIn > 0 || update.totalRateOut > 0 {
            broadcast(.traffic(update))
        }
        let review: [ReviewItem]? = configuration.withLock { configuration in
            guard configuration.reviewChanged else { return nil }
            configuration.reviewChanged = false
            return configuration.review.values.sorted { $0.lastSeen > $1.lastSeen }
        }
        if let review {
            broadcast(.review(review))
            try? store?.setSetting(review, key: "review")
        }
    }

    private func flushHistory() {
        try? store?.recordTraffic(traffic.drainHistory(), at: .now)
    }

    private func flushLog() {
        try? store?.appendLog(traffic.drainLog())
    }

    private func maintenance() {
        flushHistory()
        flushLog()
        if backups.withLock({ $0?.needsAutomaticBackup() ?? false }) {
            try? makeBackup(automatic: true)
        }
        traffic.prune()
        coordinator.reap()

        let now = Date()
        let expired = configuration.withLock { configuration in
            let expired = configuration.rules.values.filter { rule in
                if rule.lifetime.isExpired(at: now) { return true }
                if case .untilQuit(let instance) = rule.lifetime { return !ProcessResolver.isAlive(instance) }
                return false
            }.map(\.id)
            expired.forEach { configuration.rules.removeValue(forKey: $0) }
            return expired
        }
        if !expired.isEmpty {
            try? store?.delete(expired, table: "rule")
            rebuild()
            broadcastRules()
        }
        let retention = currentRules.settings.historyRetentionDays
        try? store?.pruneTraffic(retentionDays: retention, now: now)
        try? store?.pruneLog(olderThan: now - Double(min(retention, 90)) * 86_400)
    }

    // MARK: Blocklists

    private func refreshStaleBlocklists() {
        let now = Date()
        let stale = configuration.withLock { configuration in
            configuration.blocklists.values.filter { subscription in
                subscription.isEnabled && (subscription.lastUpdated.map { now.timeIntervalSince($0) >= subscription.updateInterval } ?? true)
            }.map(\.id)
        }
        for id in stale {
            Task { _ = await refreshBlocklist(id) }
        }
    }

    private func refreshBlocklist(_ id: UUID) async -> EngineResponse {
        guard let store, var subscription = configuration.withLock({ $0.blocklists[id] }) else {
            return .failure("Unknown blocklist")
        }
        do {
            let result = try await blocklistUpdater.download(subscription, to: store.blocklistDirectory)
            subscription.lastUpdated = .now
            subscription.lastError = nil
            subscription.entryCount = result.entries.count
            if subscription.name.isEmpty, let name = result.name {
                subscription.name = name
            }
            let updated = subscription
            queue.sync {
                configuration.withLock { configuration in
                    guard configuration.blocklists[id] != nil else { return }
                    configuration.blocklists[id] = updated
                    configuration.blocklistEntries[id] = result.entries
                }
                try? store.save([(id, updated)], table: "blocklist")
                rebuild()
                broadcastBlocklists()
            }
            return .blocklist(updated)
        } catch {
            subscription.lastError = error.localizedDescription
            let failed = subscription
            queue.sync {
                configuration.withLock { configuration in
                    guard configuration.blocklists[id] != nil else { return }
                    configuration.blocklists[id] = failed
                }
                try? store.save([(id, failed)], table: "blocklist")
                broadcastBlocklists()
            }
            log.error("Blocklist \(subscription.url.absoluteString, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return .failure(error.localizedDescription)
        }
    }
}

// MARK: - Rule groups, backups and migrations

extension Engine {
    static var bootTime: Date {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &time, &size, nil, 0)
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000)
    }

    /// Rules created while a process looked unsigned are keyed by its path, which breaks on every update. Now
    /// that its signature can be read, key them by signature instead.
    private func migratePathRules(_ rules: inout [Rule]) -> [Rule] {
        var migrated: [Rule] = []
        for index in rules.indices {
            var rule = rules[index]
            var changed = false
            if case .process(.path(let path)) = rule.process, let identity = ProcessResolver.staticIdentity(atPath: path), identity.signer.isTrusted {
                rule.process = .process(identity.key)
                rule.processName = identity.displayName
                changed = true
            }
            // Rules migrated by an earlier build kept the name they had while the process looked unsigned.
            if case .process(.signed(_, let signingID)) = rule.process, let name = rule.processName,
               name.first?.isNumber == true, name.allSatisfy({ $0.isNumber || $0 == "." }) {
                rule.processName = String(signingID.split(separator: ".").last ?? Substring(name))
                changed = true
            }
            if case .path(let path)? = rule.via, let identity = ProcessResolver.staticIdentity(atPath: path), identity.signer.isTrusted {
                rule.via = identity.key
                changed = true
            }
            if changed {
                rules[index] = rule
                migrated.append(rule)
            }
        }
        return migrated
    }

    private func currentConfiguration() -> ConfigurationBackup {
        configuration.withLock { configuration in
            ConfigurationBackup(
                settings: configuration.settings,
                rules: configuration.rules.values.filter { $0.lifetime == .forever },
                ruleGroups: Array(configuration.ruleGroups.values),
                profiles: configuration.profiles,
                blocklists: Array(configuration.blocklists.values)
            )
        }
    }

    private func makeBackup(automatic: Bool) throws {
        let backup = currentConfiguration()
        try backups.withLock { try $0?.save(backup, automatic: automatic) }
    }

    /// Replaces the whole configuration, keeping an automatic backup of what was there first.
    private func restore(_ backup: ConfigurationBackup) throws {
        guard let store else { return }
        try makeBackup(automatic: true)
        for table in ["rule", "rule_group", "profile", "blocklist"] {
            try store.deleteAll(table: table)
        }
        try store.save(backup.rules.map { ($0.id, $0) }, table: "rule")
        try store.save(backup.ruleGroups.map { ($0.id, $0) }, table: "rule_group")
        try store.save(backup.profiles.map { ($0.id, $0) }, table: "profile")
        try store.save(backup.blocklists.map { ($0.id, $0) }, table: "blocklist")
        try store.setSetting(backup.settings, key: "settings")
        var entries: [UUID: BlocklistEntries] = [:]
        for list in backup.blocklists {
            entries[list.id] = blocklistUpdater.loadCached(list, from: store.blocklistDirectory)
        }
        configuration.withLock { configuration in
            configuration.settings = backup.settings
            configuration.rules = Dictionary(backup.rules.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            configuration.ruleGroups = Dictionary(backup.ruleGroups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            configuration.profiles = backup.profiles
            configuration.blocklists = Dictionary(backup.blocklists.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            configuration.blocklistEntries = entries
        }
        rebuild()
        broadcast(.settings(backup.settings))
        broadcast(.profiles(backup.profiles))
        broadcastRules()
        broadcastRuleGroups()
        broadcastBlocklists()
        log.info("Restored a backup from \(backup.created.formatted(), privacy: .public)")
        refreshStaleBlocklists()
        refreshStaleRuleGroups()
    }

    private func refreshStaleRuleGroups() {
        let now = Date()
        let stale = configuration.withLock { configuration in
            configuration.ruleGroups.values.filter { group in
                guard let subscription = group.subscription, group.isEnabled else { return false }
                return subscription.lastUpdated.map { now.timeIntervalSince($0) >= subscription.updateInterval } ?? true
            }.map(\.id)
        }
        for id in stale {
            Task { _ = await refreshRuleGroup(id) }
        }
    }

    func refreshRuleGroup(_ id: UUID) async -> EngineResponse {
        guard var group = configuration.withLock({ $0.ruleGroups[id] }), let subscription = group.subscription else {
            return .failure("Unknown rule group")
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: subscription.url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw BlocklistUpdater.UpdateError.http(http.statusCode)
            }
            let result = try LittleSnitchFormat.parse(data, origin: .subscription, groupID: id) { path in
                ProcessResolver.staticIdentity(atPath: path)
            }
            group.subscription?.lastUpdated = .now
            group.subscription?.lastError = nil
            group.subscription?.skippedProcesses = result.skipped
            if group.name.isEmpty, let name = result.name { group.name = name }
            if group.note.isEmpty, let description = result.description { group.note = description }
            let updated = group
            queue.sync {
                let removed = configuration.withLock { configuration in
                    guard configuration.ruleGroups[id] != nil else { return [UUID]() }
                    let old = configuration.rules.values.filter { $0.groupID == id }.map(\.id)
                    old.forEach { configuration.rules.removeValue(forKey: $0) }
                    result.rules.forEach { configuration.rules[$0.id] = $0 }
                    configuration.ruleGroups[id] = updated
                    return old
                }
                try? store?.delete(removed, table: "rule")
                try? store?.save(result.rules.map { ($0.id, $0) }, table: "rule")
                try? store?.save([(id, updated)], table: "rule_group")
                rebuild()
                broadcastRules()
                broadcastRuleGroups()
            }
            return .ruleGroup(updated)
        } catch {
            group.subscription?.lastError = error.localizedDescription
            let failed = group
            queue.sync {
                configuration.withLock { configuration in
                    if configuration.ruleGroups[id] != nil { configuration.ruleGroups[id] = failed }
                }
                try? store?.save([(id, failed)], table: "rule_group")
                broadcastRuleGroups()
            }
            return .failure(error.localizedDescription)
        }
    }
}
