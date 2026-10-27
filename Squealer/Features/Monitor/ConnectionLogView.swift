import SquealerKit
import SwiftUI

struct ConnectionLogView: View {
    @Environment(AppModel.self) private var model
    @Bindable private var navigation = NavigationModel.shared
    @State private var entries: [ConnectionLogEntry] = []
    @State private var search = ""
    @State private var period: Period = .hour
    @State private var deniedOnly = false
    @State private var selection: ConnectionLogEntry.ID?
    @State private var sortOrder = [KeyPathComparator(\ConnectionLogEntry.start, order: .reverse)]

    enum Period: String, CaseIterable, Identifiable {
        case hour = "1H"
        case day = "24H"
        case week = "7D"
        var id: Self { self }

        var duration: TimeInterval {
            switch self {
            case .hour: 3_600
            case .day: 86_400
            case .week: 7 * 86_400
            }
        }
    }

    var body: some View {
        Group {
            if entries.isEmpty {
                EmptyStateView(title: "No Connections Logged", symbol: "list.bullet.rectangle.portrait", message: "Each connection is logged when it closes, along with how much data it used.")
            } else {
                Table(entries.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Time", value: \.start) { entry in
                        Text(entry.start.formatted(date: period == .hour ? .omitted : .abbreviated, time: .standard))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 80, ideal: 130)
                    TableColumn("App", value: \.processName) { entry in
                        HStack(spacing: 6) {
                            AppIcon(process: ProcessIdentity(path: entry.processPath, signer: .developerID, bundlePath: entry.processPath.hasSuffix(".app") ? entry.processPath : nil), size: 16)
                            Text(entry.processName).lineLimit(1)
                            if let via = entry.viaName {
                                Text("via \(via)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .width(min: 140, ideal: 200)
                    TableColumn("Server", value: \.host) { entry in
                        HStack(spacing: 4) {
                            Image(systemName: entry.direction == .inbound ? "arrow.down.left" : "arrow.up.right")
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(entry.direction == .inbound ? "Incoming" : "Outgoing")
                            Text(entry.host).lineLimit(1).truncationMode(.middle)
                            Text(":\(entry.port)").foregroundStyle(.tertiary).font(.callout.monospacedDigit())
                        }
                    }
                    .width(min: 180, ideal: 280)
                    TableColumn("Status") { entry in
                        VerdictChip(verdict: entry.verdict, compact: true)
                    }
                    .width(min: 80, ideal: 90)
                    TableColumn("Data") { entry in
                        if entry.verdict.action == .allow {
                            Text("↓ \(Format.bytes(entry.bytesIn))  ↑ \(Format.bytes(entry.bytesOut))")
                                .font(.callout.monospacedDigit())
                        }
                    }
                    .width(min: 120, ideal: 150)
                    TableColumn("Duration") { entry in
                        if let duration = entry.duration, entry.verdict.action == .allow {
                            Text(Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 60, ideal: 80)
                }
            }
        }
        .navigationTitle("Log")
        .navigationSubtitle(Plural.connections(entries.count))
        .searchable(text: $search, placement: .toolbar, prompt: "App, host or address")
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $deniedOnly) { Label("Denied Only", systemImage: "hand.raised") }
                    .help("Show only denied connections")
                Picker("Period", selection: $period) {
                    ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let process = navigation.logFilterProcess {
                HStack {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(Theme.brand)
                    Text("Showing \(entries.first?.processName ?? process.description)").font(.callout)
                    Spacer()
                    Button("Show All") { navigation.logFilterProcess = nil }.controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
            }
        }
        .task(id: QueryKey(search: search, period: period, deniedOnly: deniedOnly, process: navigation.logFilterProcess)) {
            while !Task.isCancelled {
                entries = await model.connectionLog(ConnectionLogQuery(
                    since: .now - period.duration,
                    process: navigation.logFilterProcess,
                    text: search.isEmpty ? nil : search,
                    deniedOnly: deniedOnly,
                    limit: 2_000
                ))
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private struct QueryKey: Hashable {
        var search: String
        var period: Period
        var deniedOnly: Bool
        var process: ProcessKey?
    }
}

/// The most recent connections for the inspector's selection.
struct RecentConnections: View {
    @Environment(AppModel.self) private var model
    var process: ProcessKey
    var host: String?
    @State private var entries: [ConnectionLogEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent Connections").font(.headline)
                Spacer()
                Button("Open Log") {
                    NavigationModel.shared.logFilterProcess = process
                    NavigationModel.shared.section = .log
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            if entries.isEmpty {
                Text("None logged in the last day.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(entries.prefix(8)) { entry in
                HStack {
                    Image(systemName: Theme.symbol(for: entry.verdict.action))
                        .foregroundStyle(Theme.color(for: entry.verdict.action))
                        .imageScale(.small)
                    Text(host == nil ? entry.host : entry.start.formatted(date: .omitted, time: .standard))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(host == nil ? Format.relative(entry.start) : Format.bytes(entry.bytesIn + entry.bytesOut))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.caption)
            }
        }
        .task(id: "\(process)|\(host ?? "")") {
            entries = await model.connectionLog(ConnectionLogQuery(since: .now - 86_400, process: process, host: host, limit: 8))
        }
    }
}
