import SquealerKit
import SwiftUI

struct ConnectionsView: View {
    @Environment(AppModel.self) private var model
    var filter: ConnectionRow.Filter

    @State private var search = ""
    @State private var selection: ConnectionRow.ID?
    @State private var sortOrder = [KeyPathComparator(\ConnectionRow.lastSeen, order: .reverse)]
    @Bindable private var navigation = NavigationModel.shared
    @State private var paused = false
    @State private var frozenRows: [ConnectionRow]?
    @AppStorage("monitor.showLocal") private var showLocal = false

    var body: some View {
        let rows = frozenRows ?? sortedRows
        Group {
            if rows.isEmpty {
                emptyState
            } else {
                table(rows)
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle(rows))
        .searchable(text: $search, placement: .toolbar, prompt: "Apps, hosts, app:, host:, country:, port:")
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $showLocal) {
                    Label("Local Traffic", systemImage: "house")
                }
                .help(showLocal ? "Hide traffic within your local network" : "Show traffic within your local network")
                Toggle(isOn: $paused) {
                    Label(paused ? "Resume Updates" : "Pause Updates", systemImage: paused ? "play.fill" : "pause.fill")
                }
                .help(paused ? "Resume live updates" : "Freeze the list so it stops moving")
                .onChange(of: paused) { _, isPaused in
                    frozenRows = isPaused ? sortedRows : nil
                }
                Toggle(isOn: $navigation.showConnectionInspector) {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help("Show or hide details")
            }
        }
        .onChange(of: selectedRow(in: rows), initial: true) { _, row in
            navigation.inspector = .connection(row)
        }
    }

    private var title: LocalizedStringKey {
        switch filter {
        case .all: "All Connections"
        case .active: "Active Now"
        case .blocked: "Blocked"
        }
    }

    private func subtitle(_ rows: [ConnectionRow]) -> String {
        let servers = rows.reduce(0) { $0 + ($1.children?.count ?? 0) }
        return Plural.appsAndServers(rows.count, servers)
    }

    private var sortedRows: [ConnectionRow] {
        var rows = ConnectionRow.tree(from: model.connections.values, filter: filter, search: search, includeLocal: showLocal)
        rows.sort(using: sortOrder)
        for index in rows.indices {
            rows[index].children?.sort(using: sortOrder)
        }
        return rows
    }

    private func selectedRow(in rows: [ConnectionRow]) -> ConnectionRow? {
        guard let selection else { return nil }
        for row in rows {
            if row.id == selection { return row }
            if let child = row.children?.first(where: { $0.id == selection }) { return child }
        }
        return nil
    }

    private func table(_ rows: [ConnectionRow]) -> some View {
        let maximumRate = max(rows.map(\.rate).max() ?? 0, 1)
        return Table(rows, children: \.children, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                NameCell(row: row)
            }
            .width(min: 220, ideal: 320)

            TableColumn("Status") { row in
                if let verdict = row.verdict {
                    VerdictChip(verdict: verdict, compact: row.kind == .app)
                } else {
                    Pill(text: "Mixed", symbol: "circle.lefthalf.filled", color: .secondary)
                }
            }
            .width(min: 90, ideal: 120)

            TableColumn("Activity", value: \.rate) { row in
                HStack(spacing: 8) {
                    RateBar(bytesIn: row.rateIn, bytesOut: row.rateOut, maximum: maximumRate)
                        .frame(width: 60)
                    Text(Format.rate(row.rate))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(row.rate > 0 ? .primary : .tertiary)
                }
            }
            .width(min: 120, ideal: 150)

            TableColumn("Data", value: \.totalBytes) { row in
                HStack(spacing: 8) {
                    Text("↓ \(Format.bytes(row.bytesIn))").foregroundStyle(Theme.inbound)
                    Text("↑ \(Format.bytes(row.bytesOut))").foregroundStyle(Theme.outbound)
                }
                .font(.callout.monospacedDigit())
            }
            .width(min: 140, ideal: 170)

            TableColumn("Connections", value: \.totalFlows) { row in
                HStack(spacing: 4) {
                    Text("\(row.totalFlows)")
                    if row.deniedFlows > 0 {
                        Text("· \(row.deniedFlows) denied").foregroundStyle(Theme.deny)
                    }
                }
                .font(.callout.monospacedDigit())
            }
            .width(min: 80, ideal: 120)

            TableColumn("Last Seen", value: \.lastSeen) { row in
                Text(row.activeFlows > 0 ? String(localized: "Active") : Format.relative(row.lastSeen))
                    .foregroundStyle(row.activeFlows > 0 ? Theme.allow : .secondary)
                    .font(.callout)
            }
            .width(min: 70, ideal: 90)
        }
        .contextMenu(forSelectionType: ConnectionRow.ID.self) { ids in
            if let id = ids.first, let row = selectedRowByID(id, in: rows) {
                ConnectionActions(row: row)
            }
        }
    }

    private func selectedRowByID(_ id: ConnectionRow.ID, in rows: [ConnectionRow]) -> ConnectionRow? {
        for row in rows {
            if row.id == id { return row }
            if let child = row.children?.first(where: { $0.id == id }) { return child }
        }
        return nil
    }

    @ViewBuilder
    private var emptyState: some View {
        if !search.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            switch filter {
            case .all: EmptyStateView(title: "No Connections Yet", symbol: "point.3.connected.trianglepath.dotted", message: "Connections appear here as soon as apps use the network.")
            case .active: EmptyStateView(title: "All Quiet", symbol: "moon.zzz", message: "Nothing is using the network right now.")
            case .blocked: EmptyStateView(title: "Nothing Blocked", symbol: "hand.raised", message: "Connections denied by your rules or blocklists show up here.")
            }
        }
    }
}

private struct NameCell: View {
    var row: ConnectionRow

    var body: some View {
        switch row.kind {
        case .app:
            HStack(spacing: 8) {
                AppIcon(process: row.process, size: 18)
                Text(row.name).fontWeight(.medium).lineLimit(1)
                if row.activeFlows > 0 {
                    Circle().fill(Theme.allow).frame(width: 6, height: 6)
                        .help("\(row.activeFlows) open connections")
                }
            }
        case .endpoint(let summary):
            HStack(spacing: 6) {
                Image(systemName: summary.endpoint.direction == .inbound ? "arrow.down.left.circle" : "arrow.up.right.circle")
                    .foregroundStyle(summary.endpoint.direction == .inbound ? Theme.inbound : .secondary)
                    .help(summary.endpoint.direction == .inbound ? "Incoming" : "Outgoing")
                if let flag = GeoService.shared.location(for: summary.remoteAddress)?.flag {
                    Text(flag)
                }
                Text(row.name).lineLimit(1).truncationMode(.middle)
                Text(":\(summary.endpoint.port)")
                    .foregroundStyle(.tertiary)
                    .font(.callout.monospacedDigit())
                if let via = summary.via {
                    Text("via \(ProcessPresentation.name(for: via))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

struct ConnectionActions: View {
    @Environment(AppModel.self) private var model
    var row: ConnectionRow

    var body: some View {
        switch row.kind {
        case .app:
            Button("Allow All Connections from \(row.name)") {
                model.quickRule(process: row.process, remote: .any, action: .allow)
            }
            Button("Deny All Connections from \(row.name)") {
                model.quickRule(process: row.process, remote: .any, action: .deny)
            }
            Divider()
            Button("Show Rules for \(row.name)") {
                NavigationModel.shared.ruleFilterProcess = row.process.key
                NavigationModel.shared.section = .rules
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(row.process.bundlePath ?? row.process.path, inFileViewerRootedAtPath: "")
            }
        case .endpoint(let summary):
            let host = summary.endpoint.host
            let domain = DomainName.registrableDomain(of: host)
            let remote = remoteMatcher(for: summary)
            Button("Allow \(host)") { model.quickRule(process: row.process, remote: remote, action: .allow, direction: summary.endpoint.direction) }
            Button("Deny \(host)") { model.quickRule(process: row.process, remote: remote, action: .deny, direction: summary.endpoint.direction) }
            if summary.remoteAddress.map({ IPAddress(host) != $0 }) ?? true, domain != host {
                Divider()
                Button("Allow *.\(domain)") { model.quickRule(process: row.process, remote: .domain(domain), action: .allow) }
                Button("Deny *.\(domain)") { model.quickRule(process: row.process, remote: .domain(domain), action: .deny) }
                Button("Deny *.\(domain) for Every App") { model.quickRule(process: nil, remote: .domain(domain), action: .deny) }
            }
            Divider()
            Button("Copy Host") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(host, forType: .string)
            }
            if let address = summary.remoteAddress {
                Button("Copy Address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(address.description, forType: .string)
                }
            }
        }
    }

    private func remoteMatcher(for summary: ConnectionSummary) -> RemoteMatcher {
        if let address = IPAddress(summary.endpoint.host) { return .address(address) }
        return .host(summary.endpoint.host)
    }
}

extension AppModel {
    func quickRule(process: ProcessIdentity?, remote: RemoteMatcher, action: RuleAction, direction: Direction = .outbound) {
        save([Rule(
            process: process.map { .process($0.key) } ?? .any,
            direction: direction,
            remote: remote,
            action: action,
            origin: .user,
            processName: process.map(ProcessPresentation.name(for:)),
            processPath: process.map { $0.bundlePath ?? $0.path }
        )])
    }
}
