import Foundation
import Observation
import os
import SquealerKit

/// Everything the UI shows, mirrored from the engine and kept current by its event stream.
@MainActor @Observable
final class AppModel {
    enum Connection: Equatable {
        case disconnected
        case connecting
        case connected(engineVersion: String)

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    struct RateSample: Identifiable, Hashable {
        var date: Date
        var bytesIn: Double
        var bytesOut: Double
        var id: Date { date }
    }

    private(set) var connection: Connection = .disconnected {
        didSet {
            if connection.isConnected { disconnectedSince = nil } else if disconnectedSince == nil { disconnectedSince = .now }
        }
    }
    /// When the app last lost the extension; used to offer a restart if it doesn't come back.
    private(set) var disconnectedSince: Date? = .now
    private(set) var settings = EngineSettings()
    private(set) var rules: [Rule] = []
    private(set) var ruleGroups: [RuleGroup] = []
    private(set) var profiles: [Profile] = []
    private(set) var blocklists: [BlocklistSubscription] = []
    private(set) var alerts: [ConnectionAlert] = []
    private(set) var connections: [ConnectionSummary.ID: ConnectionSummary] = [:]
    private(set) var review: [ReviewItem] = []
    private(set) var rateHistory: [RateSample] = []
    private(set) var currentRate = RateSample(date: .now, bytesIn: 0, bytesOut: 0)
    var lastError: String?

    @ObservationIgnored let backend: EngineBackend
    @ObservationIgnored let isDemo: Bool
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var unlockedUntil: Date?
    @ObservationIgnored private let logger = Logger(subsystem: XPCConstants.logSubsystem, category: "model")
    private static let rateHistoryLength = 90

    init(backend: EngineBackend, isDemo: Bool = false) {
        self.backend = backend
        self.isDemo = isDemo
    }

    func start() {
        guard tasks.isEmpty else { return }
        tasks.append(Task { [weak self, backend] in
            for await event in backend.events {
                self?.apply(event)
            }
        })
        tasks.append(Task { [weak self, backend] in
            for await connected in backend.connectionChanges {
                guard let self else { return }
                if connected {
                    await self.handshake()
                } else {
                    self.connection = .disconnected
                    self.alerts = []
                }
            }
        })
        connect()
    }

    func connect() {
        guard !connection.isConnected else { return }
        connection = .connecting
        backend.connect()
    }

    private func handshake() async {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        do {
            guard case .snapshot(let snapshot) = try await backend.send(.hello(clientVersion: version)) else { return }
            settings = snapshot.settings
            rules = snapshot.rules
            ruleGroups = snapshot.ruleGroups
            profiles = snapshot.profiles
            blocklists = snapshot.blocklists
            alerts = snapshot.pendingAlerts
            connections = Dictionary(snapshot.connections.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
            review = snapshot.review
            connection = .connected(engineVersion: snapshot.engineVersion)
            Task { await perform(.endLogoutSessions(except: Session.current.loginSession)) }
        } catch {
            logger.error("Handshake failed: \(error.localizedDescription, privacy: .public)")
            connection = .disconnected
        }
    }

    private func apply(_ event: EngineEvent) {
        switch event {
        case .alert(let alert):
            if let index = alerts.firstIndex(where: { $0.id == alert.id }) {
                alerts[index] = alert
            } else {
                alerts.append(alert)
            }
        case .alertWithdrawn(let id):
            alerts.removeAll { $0.id == id }
        case .traffic(let update):
            for summary in update.connections {
                connections[summary.id] = summary
            }
            currentRate = RateSample(date: update.timestamp, bytesIn: update.totalRateIn, bytesOut: update.totalRateOut)
            rateHistory.append(currentRate)
            if rateHistory.count > Self.rateHistoryLength {
                rateHistory.removeFirst(rateHistory.count - Self.rateHistoryLength)
            }
        case .rules(let rules):
            self.rules = rules
        case .settings(let settings):
            self.settings = settings
        case .profiles(let profiles):
            self.profiles = profiles
        case .blocklists(let blocklists):
            self.blocklists = blocklists
        case .review(let review):
            self.review = review
        case .ruleGroups(let groups):
            ruleGroups = groups
        }
    }

    // MARK: Actions

    @discardableResult
    private func perform(_ request: EngineRequest) async -> EngineResponse? {
        do {
            return try await backend.send(request)
        } catch {
            lastError = error.localizedDescription
            logger.error("Request failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func update(_ change: (inout EngineSettings) -> Void) {
        var updated = settings
        change(&updated)
        // Turning protection off must itself be authorised, so check against the current settings.
        let previous = settings
        guard updated != previous else { return }
        Task {
            guard await authorize(previous) else { return }
            settings = updated
            await perform(.setSettings(updated))
        }
    }

    /// Asks for Touch ID or the login password before a protected change, then stays unlocked for a few
    /// minutes so a burst of edits doesn't prompt every time.
    func authorize(_ settings: EngineSettings? = nil) async -> Bool {
        guard (settings ?? self.settings).requireAuthentication, !isDemo else { return true }
        if let unlockedUntil, unlockedUntil > .now { return true }
        let granted = await Authentication.request(reason: String(localized: "change Squealer's rules and settings"))
        if granted { unlockedUntil = .now + 300 }
        return granted
    }

    func setMode(_ mode: FilterMode) {
        update { $0.mode = mode }
    }

    func activateProfile(_ id: UUID?) {
        update { $0.activeProfileID = id }
    }

    func save(_ rules: [Rule]) {
        Task {
            guard await authorize() else { return }
            apply(rules)
            await perform(.upsertRules(rules))
        }
    }

    private func apply(_ rules: [Rule]) {
        for rule in rules {
            if let index = self.rules.firstIndex(where: { $0.id == rule.id }) {
                self.rules[index] = rule
            } else {
                self.rules.append(rule)
            }
        }
    }

    func deleteRules(_ ids: Set<UUID>) {
        Task {
            guard await authorize() else { return }
            rules.removeAll { ids.contains($0.id) }
            await perform(.deleteRules(Array(ids)))
        }
    }

    func save(_ profile: Profile) {
        Task { guard await authorize() else { return }; saveUnchecked(profile) }
    }

    private func saveUnchecked(_ profile: Profile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        Task { await perform(.upsertProfile(profile)) }
    }

    func deleteProfile(_ id: UUID) {
        Task {
            guard await authorize() else { return }
            profiles.removeAll { $0.id == id }
            await perform(.deleteProfile(id))
        }
    }

    func save(_ blocklist: BlocklistSubscription) {
        Task { guard await authorize() else { return }; saveUnchecked(blocklist) }
    }

    private func saveUnchecked(_ blocklist: BlocklistSubscription) {
        if let index = blocklists.firstIndex(where: { $0.id == blocklist.id }) {
            blocklists[index] = blocklist
        } else {
            blocklists.append(blocklist)
        }
        Task { await perform(.upsertBlocklist(blocklist)) }
    }

    func deleteBlocklist(_ id: UUID) {
        Task {
            guard await authorize() else { return }
            blocklists.removeAll { $0.id == id }
            await perform(.deleteBlocklist(id))
        }
    }

    func refreshBlocklist(_ id: UUID) async {
        await perform(.refreshBlocklist(id))
    }

    var unapprovedRules: [Rule] {
        rules.filter { !$0.isApproved }
    }

    func approve(_ ids: Set<UUID>) {
        save(rules.filter { ids.contains($0.id) && !$0.isApproved }.map { var rule = $0; rule.isApproved = true; return rule })
    }

    func resolve(_ alert: ConnectionAlert, outcome: AlertDecision.Outcome) {
        alerts.removeAll { $0.id == alert.id }
        Task { await perform(.resolveAlert(AlertDecision(alertID: alert.id, outcome: outcome))) }
    }

    func dismissReview(_ ids: [UUID]) {
        let set = Set(ids)
        review.removeAll { set.contains($0.id) }
        Task { await perform(.dismissReview(ids)) }
    }

    func trafficHistory(_ query: TrafficHistoryQuery) async -> [TrafficBucket] {
        guard case .history(let buckets)? = await perform(.trafficHistory(query)) else { return [] }
        return buckets
    }

    func clearHistory() {
        Task {
            guard await authorize() else { return }
            connections = [:]
            rateHistory = []
            await perform(.clearHistory)
        }
    }

    func eraseAllData() async -> Bool {
        guard await authorize() else { return false }
        guard case .ok? = await perform(.eraseAllData) else { return false }
        return true
    }

    // MARK: Rule groups

    func save(_ group: RuleGroup) {
        Task {
            guard await authorize() else { return }
            if let index = ruleGroups.firstIndex(where: { $0.id == group.id }) {
                ruleGroups[index] = group
            } else {
                ruleGroups.append(group)
            }
            await perform(.upsertRuleGroup(group))
        }
    }

    func deleteGroup(_ id: UUID, deleteRules: Bool) {
        Task {
            guard await authorize() else { return }
            ruleGroups.removeAll { $0.id == id }
            await perform(.deleteRuleGroup(id, deleteRules: deleteRules))
        }
    }

    func refreshGroup(_ id: UUID) async {
        await perform(.refreshRuleGroup(id))
    }

    func group(withID id: UUID?) -> RuleGroup? {
        id.flatMap { id in ruleGroups.first { $0.id == id } }
    }

    // MARK: Log and backups

    func connectionLog(_ query: ConnectionLogQuery) async -> [ConnectionLogEntry] {
        guard case .log(let entries)? = await perform(.connectionLog(query)) else { return [] }
        return entries
    }

    func backups() async -> [BackupInfo] {
        guard case .backups(let list)? = await perform(.listBackups) else { return [] }
        return list
    }

    func createBackup() async -> [BackupInfo] {
        guard await authorize(), case .backups(let list)? = await perform(.createBackup) else { return await backups() }
        return list
    }

    func restoreBackup(_ id: String) async -> Bool {
        guard await authorize() else { return false }
        return await perform(.restoreBackup(id)) != nil
    }

    func exportConfiguration() async -> ConfigurationBackup? {
        guard case .configuration(let backup)? = await perform(.exportConfiguration) else { return nil }
        return backup
    }

    func restore(_ backup: ConfigurationBackup) async -> Bool {
        guard await authorize() else { return false }
        return await perform(.restoreConfiguration(backup)) != nil
    }

    func endLoginSession() {
        Task { await perform(.endLogoutSessions(except: "")) }
    }

    // MARK: Derived

    var activeProfile: Profile? {
        settings.activeProfileID.flatMap { id in profiles.first { $0.id == id } }
    }

    func rule(withID id: UUID) -> Rule? {
        rules.first { $0.id == id }
    }

    var blocklistNames: [UUID: String] {
        Dictionary(blocklists.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    func describe(_ rule: Rule) -> String {
        RuleText.sentence(for: rule, blocklistNames: blocklistNames)
    }
}
