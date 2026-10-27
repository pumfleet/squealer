import Charts
import SquealerKit
import SwiftUI

struct ConnectionInspector: View {
    @Environment(AppModel.self) private var model
    var row: ConnectionRow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let summary = row.summary {
                    endpointSection(summary)
                }
                statistics
                TrafficHistoryChart(process: row.process.key, host: row.summary?.endpoint.host)
                RecentConnections(process: row.process.key, host: row.summary?.endpoint.host)
                rulesSection
                processSection
            }
            .padding(16)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AppIcon(process: row.process, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(ProcessPresentation.name(for: row.process))
                    .font(.title3.weight(.semibold))
                SignerBadge(process: row.process)
                if let description = KnowledgeBase.processDescription(signingID: row.process.signingID) {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func endpointSection(_ summary: ConnectionSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(summary.endpoint.direction == .inbound ? "Incoming from" : "Connecting to")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(summary.endpoint.host)
                .font(.title3.weight(.medium))
                .textSelection(.enabled)
            if let service = KnowledgeBase.service(for: summary.endpoint.host) {
                ServiceBadge(service: service)
            }
            GeoLabel(address: summary.remoteAddress)
            if summary.hostnameSource == .none, let address = summary.remoteAddress {
                ReverseNameLabel(address: address)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                KeyValueRow(key: "Port", value: Format.port(summary.endpoint.port, transport: summary.endpoint.transport))
                if let address = summary.remoteAddress {
                    KeyValueRow(key: "Address", value: address.description, monospaced: true)
                }
                KeyValueRow(key: "Name from", value: hostnameSource(summary.hostnameSource))
                if let via = summary.via {
                    KeyValueRow(key: "Via", value: ProcessPresentation.name(for: via))
                }
            }
            .font(.caption)
            HStack {
                Button {
                    model.quickRule(process: row.process, remote: remote(summary), action: .allow, direction: summary.endpoint.direction)
                } label: { Label("Allow", systemImage: "checkmark") }
                Button {
                    model.quickRule(process: row.process, remote: remote(summary), action: .deny, direction: summary.endpoint.direction)
                } label: { Label("Deny", systemImage: "xmark") }
            }
            .controlSize(.small)
            .padding(.top, 4)
        }
        .card()
    }

    private var statistics: some View {
        Grid(horizontalSpacing: 16, verticalSpacing: 10) {
            GridRow {
                Statistic(title: "Received", value: Format.bytes(row.bytesIn), color: Theme.inbound)
                Statistic(title: "Sent", value: Format.bytes(row.bytesOut), color: Theme.outbound)
            }
            GridRow {
                Statistic(title: "Connections", value: "\(row.totalFlows)", color: .primary)
                Statistic(title: "Denied", value: "\(row.deniedFlows)", color: row.deniedFlows > 0 ? Theme.deny : .primary)
            }
        }
        .card()
    }

    @ViewBuilder
    private var rulesSection: some View {
        let rules = matchingRules
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Rules").font(.headline)
                Spacer()
                Button("Show All") {
                    NavigationModel.shared.ruleFilterProcess = row.process.key
                    NavigationModel.shared.section = .rules
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            if rules.isEmpty {
                Text(row.verdict?.kind == .builtin ? "Allowed by a built-in default, not a rule." : "No rules for this app yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(rules) { rule in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: Theme.symbol(for: rule.action))
                        .foregroundStyle(Theme.color(for: rule.action))
                    Text(model.describe(rule))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    if rule.id == row.verdict?.ruleID {
                        Pill(text: "Applied", symbol: nil, color: Theme.brand)
                    }
                }
            }
        }
    }

    private var processSection: some View {
        DisclosureGroup("Code Signature") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                KeyValueRow(key: "Path", value: row.process.path, monospaced: true)
                if let id = row.process.signingID { KeyValueRow(key: "Identifier", value: id, monospaced: true) }
                if let team = row.process.teamID { KeyValueRow(key: "Team", value: team, monospaced: true) }
                if let cdhash = row.process.cdhash { KeyValueRow(key: "CDHash", value: cdhash, monospaced: true) }
            }
            .font(.caption)
            .padding(.top, 4)
        }
    }

    private var matchingRules: [Rule] {
        let key = row.process.key
        return model.rules.filter { rule in
            guard rule.process == .process(key) || rule.process == .any else { return false }
            guard let summary = row.summary else { return rule.process != .any }
            switch rule.remote {
            case .any: return true
            case .host(let host): return host == summary.endpoint.host
            case .domain(let domain): return RuleEngine.hostname(summary.endpoint.host, isWithin: domain)
            case .address(let address): return summary.remoteAddress == address
            case .network(let network): return summary.remoteAddress.map(network.contains) ?? false
            case .localNetwork: return summary.remoteAddress?.isLocal ?? false
            case .blocklist: return rule.id == summary.lastVerdict.ruleID
            }
        }
        .sorted { ($0.id == row.verdict?.ruleID ? 0 : 1, $0.createdAt) < ($1.id == row.verdict?.ruleID ? 0 : 1, $1.createdAt) }
    }

    private func remote(_ summary: ConnectionSummary) -> RemoteMatcher {
        if let address = IPAddress(summary.endpoint.host) { return .address(address) }
        return .host(summary.endpoint.host)
    }

    private func hostnameSource(_ source: HostnameSource) -> String {
        switch source {
        case .flow: String(localized: "The app")
        case .dns: String(localized: "Observed DNS lookup")
        case .reverse: String(localized: "Reverse lookup")
        case .none: String(localized: "Unknown (address only)")
        }
    }
}

private struct Statistic: View {
    var title: LocalizedStringKey
    var value: String
    var color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TrafficHistoryChart: View {
    @Environment(AppModel.self) private var model
    var process: ProcessKey?
    var host: String?

    enum Range: String, CaseIterable, Identifiable {
        case hour = "1H"
        case day = "24H"
        case week = "7D"
        case month = "30D"
        var id: Self { self }

        var duration: TimeInterval {
            switch self {
            case .hour: 3_600
            case .day: 86_400
            case .week: 7 * 86_400
            case .month: 30 * 86_400
            }
        }

        var granularity: TrafficHistoryQuery.Granularity { self == .hour ? .minute : .hour }
        var unit: Calendar.Component {
            switch self {
            case .hour: .minute
            case .day, .week: .hour
            case .month: .day
            }
        }
    }

    @State private var range: Range = .day
    @State private var buckets: [TrafficBucket] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("History").font(.headline)
                Spacer()
                Picker("Range", selection: $range) {
                    ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Chart {
                ForEach(aggregated) { bucket in
                    BarMark(x: .value("Time", bucket.start, unit: range.unit), y: .value("Received", Double(bucket.bytesIn)))
                        .foregroundStyle(by: .value("Direction", String(localized: "Received")))
                    BarMark(x: .value("Time", bucket.start, unit: range.unit), y: .value("Sent", Double(bucket.bytesOut)))
                        .foregroundStyle(by: .value("Direction", String(localized: "Sent")))
                }
            }
            .chartForegroundStyleScale([String(localized: "Received"): Theme.inbound, String(localized: "Sent"): Theme.outbound])
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let bytes = value.as(Double.self) { Text(Format.bytes(UInt64(max(0, bytes)))) }
                    }
                }
            }
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: 150)
            .overlay {
                if buckets.isEmpty {
                    Text("No traffic recorded in this period")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: TaskKey(range: range, process: process, host: host)) {
            buckets = await model.trafficHistory(TrafficHistoryQuery(
                start: .now - range.duration,
                end: .now + 60,
                granularity: range.granularity,
                process: process,
                host: host
            ))
        }
    }

    private struct TaskKey: Hashable {
        var range: Range
        var process: ProcessKey?
        var host: String?
    }

    private var aggregated: [TrafficBucket] {
        guard range == .month else { return buckets }
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: buckets) { calendar.startOfDay(for: $0.start) }
        return grouped.map { day, items in
            TrafficBucket(
                start: day,
                bytesIn: items.reduce(0) { $0 + $1.bytesIn },
                bytesOut: items.reduce(0) { $0 + $1.bytesOut },
                connections: items.reduce(0) { $0 + $1.connections },
                denied: items.reduce(0) { $0 + $1.denied }
            )
        }
        .sorted { $0.start < $1.start }
    }
}
