import SquealerKit
import SwiftUI

enum MainSection: Hashable {
    case connections
    case active
    case blocked
    case review
    case log
    case map
    case rules
    case ruleGroups
    case blocklists
    case profiles
}

@MainActor @Observable
final class NavigationModel {
    static let shared = NavigationModel()
    var section: MainSection = .connections
    var ruleFilterProcess: ProcessKey?
    var ruleFilterGroup: UUID?
    var logFilterProcess: ProcessKey?
}

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(ExtensionManager.self) private var extensionManager
    @Bindable private var navigation = NavigationModel.shared

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { navigation.section }, set: { navigation.section = $0 ?? .connections })) {
                Section("Network") {
                    Label("All Connections", systemImage: "point.3.connected.trianglepath.dotted").tag(MainSection.connections)
                    Label("Active Now", systemImage: "waveform")
                        .badge(activeCount)
                        .tag(MainSection.active)
                    Label("Blocked", systemImage: "hand.raised.fill").tag(MainSection.blocked)
                    Label("Review", systemImage: "tray.full")
                        .badge(model.review.count)
                        .tag(MainSection.review)
                    Label("Log", systemImage: "list.bullet.rectangle.portrait").tag(MainSection.log)
                    Label("Map", systemImage: "globe.europe.africa").tag(MainSection.map)
                }
                Section("Protection") {
                    Label("Rules", systemImage: "list.bullet.rectangle")
                        .badge(model.rules.count)
                        .tag(MainSection.rules)
                    Label("Rule Groups", systemImage: "folder").tag(MainSection.ruleGroups)
                    Label("Blocklists", systemImage: "shield.checkered").tag(MainSection.blocklists)
                    Label("Profiles", systemImage: "person.2.crop.square.stack").tag(MainSection.profiles)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) {
                SidebarStatus()
                    .padding(10)
            }
        } detail: {
            detail
        }
        .frame(minWidth: 960, minHeight: 560)
        .overlay(alignment: .top) {
            if !model.connection.isConnected && !model.isDemo {
                DisconnectedBanner()
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.section {
        case .connections: ConnectionsView(filter: .all)
        case .active: ConnectionsView(filter: .active)
        case .blocked: ConnectionsView(filter: .blocked)
        case .review: ReviewView()
        case .log: ConnectionLogView()
        case .ruleGroups: RuleGroupsView()
        case .map: TrafficMapView()
        case .rules: RulesView()
        case .blocklists: BlocklistsView()
        case .profiles: ProfilesView()
        }
    }

    private var activeCount: Int {
        Set(model.connections.values.filter { $0.activeFlows > 0 }.map(\.process.key)).count
    }
}

private struct SidebarStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ModeSwitcher(compact: true)
            Text(Theme.summary(for: model.settings.mode))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            TrafficSparkline(samples: model.rateHistory)
                .frame(height: 30)
            RateLegend(bytesIn: model.currentRate.bytesIn, bytesOut: model.currentRate.bytesOut)
        }
        .card()
    }
}

private struct DisconnectedBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(ExtensionManager.self) private var extensionManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .foregroundStyle(Theme.pending)
            Text(extensionManager.status.isRunning ? "Connecting to the network extension…" : "The network extension isn't running, so nothing is being filtered.")
                .font(.callout)
            if !extensionManager.status.isRunning {
                Button("Set Up…") { openWindow(id: "onboarding") }
                    .controlSize(.small)
            } else if let since = model.disconnectedSince, Date.now.timeIntervalSince(since) > 20 {
                Button("Restart Extension") { Task { await extensionManager.restartFilter() } }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .padding(.top, 8)
    }
}
