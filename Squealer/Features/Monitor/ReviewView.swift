import SquealerKit
import SwiftUI

/// Connections decided without asking (silent mode, "decide later", Squealer not running, timeouts), so the
/// user can turn them into rules at their own pace.
struct ReviewView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<ReviewItem.ID>()
    @AppStorage("review.scope") private var scope: AlertScope.Remote = .domain

    var body: some View {
        Group {
            if model.review.isEmpty {
                EmptyStateView(
                    title: "Nothing to Review",
                    symbol: "checkmark.seal",
                    message: "Connections allowed or denied without asking you, for example in silent mode, collect here so you can make rules for them later."
                )
            } else {
                List(selection: $selection) {
                    ForEach(groupedByApp, id: \.key) { key, items in
                        Section {
                            ForEach(items) { item in
                                ReviewRow(item: item, scope: scope)
                                    .tag(item.id)
                            }
                        } header: {
                            ProcessLabel(process: items[0].flow.process, iconSize: 16)
                                .font(.headline)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Review")
        .navigationSubtitle(Plural.connections(model.review.count))
        .toolbar {
            ToolbarItemGroup {
                Picker("Rule scope", selection: $scope) {
                    Text("Host").tag(AlertScope.Remote.host)
                    Text("Domain").tag(AlertScope.Remote.domain)
                    Text("Any Server").tag(AlertScope.Remote.any)
                }
                .pickerStyle(.menu)
                .help("What new rules created here should cover")
                Button {
                    createRules(for: targets, action: .allow)
                } label: { Label("Allow", systemImage: "checkmark.circle") }
                    .help("Create allow rules for the selected connections")
                Button {
                    createRules(for: targets, action: .deny)
                } label: { Label("Deny", systemImage: "xmark.octagon") }
                    .help("Create deny rules for the selected connections")
                Button {
                    model.dismissReview(targets.map(\.id))
                    selection.removeAll()
                } label: { Label("Dismiss", systemImage: "tray.and.arrow.up") }
                    .help("Remove from this list without creating rules")
            }
        }
    }

    private var targets: [ReviewItem] {
        selection.isEmpty ? model.review : model.review.filter { selection.contains($0.id) }
    }

    private var groupedByApp: [(key: String, value: [ReviewItem])] {
        Dictionary(grouping: model.review) { $0.flow.process.key.description }
            .map { ($0.key, $0.value.sorted { $0.lastSeen > $1.lastSeen }) }
            .sorted { ($0.value.first?.lastSeen ?? .distantPast) > ($1.value.first?.lastSeen ?? .distantPast) }
    }

    private func createRules(for items: [ReviewItem], action: RuleAction) {
        let rules = items.compactMap { RuleBuilder.rule(for: $0.flow, action: action, scope: AlertScope(remote: scope, ports: .any, duration: .forever)) }
        var seen = Set<String>()
        let unique = rules.filter { seen.insert("\($0.process)|\($0.remote)|\($0.direction)").inserted }
        model.save(unique.map { var rule = $0; rule.origin = .user; return rule })
        model.dismissReview(items.map(\.id))
        selection.removeAll()
    }
}

private struct ReviewRow: View {
    @Environment(AppModel.self) private var model
    var item: ReviewItem
    var scope: AlertScope.Remote

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: Theme.symbol(for: item.action))
                .foregroundStyle(Theme.color(for: item.action))
                .help(item.action == .allow ? "Was allowed" : "Was denied")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.flow.remoteDisplayName).fontWeight(.medium)
                    Text(":\(item.flow.direction == .inbound ? item.flow.localPort : item.flow.remotePort)")
                        .foregroundStyle(.tertiary)
                    if item.attempts > 1 {
                        Text("×\(item.attempts)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                    GeoLabel(address: item.flow.remoteAddress, showOrganization: false)
                }
            }
            Spacer()
            Text(Format.relative(item.lastSeen)).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Button("Allow") { decide(.allow) }
                Button("Deny") { decide(.deny) }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private var reason: String {
        switch item.reason {
        case .silent: String(localized: "Silent mode")
        case .noClient: String(localized: "Squealer wasn't running")
        case .timeout: String(localized: "Alert timed out")
        case .once: String(localized: "Decided later")
        case .builtin: String(localized: "Unrequested incoming traffic")
        default: String(localized: "Decided automatically")
        }
    }

    private func decide(_ action: RuleAction) {
        if var rule = RuleBuilder.rule(for: item.flow, action: action, scope: AlertScope(remote: scope, ports: .any, duration: .forever)) {
            rule.origin = .user
            model.save([rule])
        }
        model.dismissReview([item.id])
    }
}
