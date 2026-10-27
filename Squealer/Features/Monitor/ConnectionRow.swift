import Foundation
import SquealerKit

/// A row in the monitor: either an app (with its endpoints as children) or a single endpoint.
struct ConnectionRow: Identifiable, Hashable {
    enum Kind: Hashable {
        case app
        case endpoint(ConnectionSummary)
    }

    var id: String
    var kind: Kind
    var process: ProcessIdentity
    var via: ProcessIdentity?
    var name: String
    var rateIn: Double
    var rateOut: Double
    var bytesIn: UInt64
    var bytesOut: UInt64
    var activeFlows: Int
    var totalFlows: Int
    var deniedFlows: Int
    var lastSeen: Date
    var verdict: VerdictInfo?
    var children: [ConnectionRow]?

    var rate: Double { rateIn + rateOut }
    var totalBytes: UInt64 { bytesIn + bytesOut }

    var summary: ConnectionSummary? {
        if case .endpoint(let summary) = kind { return summary }
        return nil
    }

    enum Filter {
        case all
        case active
        case blocked
    }

    @MainActor
    static func tree(from summaries: some Collection<ConnectionSummary>, filter: Filter, search: String, includeLocal: Bool) -> [ConnectionRow] {
        let query = SearchQuery(search)
        var groups: [ProcessKey: [ConnectionSummary]] = [:]
        for summary in summaries {
            switch filter {
            case .all: break
            case .active: guard summary.activeFlows > 0 || summary.rateIn + summary.rateOut > 0 else { continue }
            case .blocked: guard summary.deniedFlows > 0 else { continue }
            }
            if !includeLocal, summary.remoteAddress?.isLocal == true { continue }
            guard query.matches(summary) else { continue }
            groups[summary.process.key, default: []].append(summary)
        }

        return groups.map { key, summaries in
            let process = summaries.max { $0.lastSeen < $1.lastSeen }!.process
            let children = summaries.map { summary in
                ConnectionRow(
                    id: "\(key)|\(summary.via?.key.description ?? "")|\(summary.endpoint.host)|\(summary.endpoint.port)|\(summary.endpoint.transport.rawValue)|\(summary.endpoint.direction.rawValue)",
                    kind: .endpoint(summary),
                    process: summary.process,
                    via: summary.via,
                    name: summary.endpoint.host,
                    rateIn: summary.rateIn,
                    rateOut: summary.rateOut,
                    bytesIn: summary.bytesIn,
                    bytesOut: summary.bytesOut,
                    activeFlows: summary.activeFlows,
                    totalFlows: summary.totalFlows,
                    deniedFlows: summary.deniedFlows,
                    lastSeen: summary.lastSeen,
                    verdict: summary.lastVerdict
                )
            }
            let verdicts = Set(children.compactMap { $0.verdict?.action })
            return ConnectionRow(
                id: key.description,
                kind: .app,
                process: process,
                via: nil,
                name: ProcessPresentation.name(for: process),
                rateIn: children.reduce(0) { $0 + $1.rateIn },
                rateOut: children.reduce(0) { $0 + $1.rateOut },
                bytesIn: children.reduce(0) { $0 + $1.bytesIn },
                bytesOut: children.reduce(0) { $0 + $1.bytesOut },
                activeFlows: children.reduce(0) { $0 + $1.activeFlows },
                totalFlows: children.reduce(0) { $0 + $1.totalFlows },
                deniedFlows: children.reduce(0) { $0 + $1.deniedFlows },
                lastSeen: children.map(\.lastSeen).max() ?? .distantPast,
                verdict: verdicts.count == 1 ? children.first?.verdict : nil,
                children: children
            )
        }
    }
}

/// Free text plus `app:`, `host:`, `country:` and `port:` tokens, all of which must match.
struct SearchQuery {
    private var terms: [(key: String?, value: String)] = []

    init(_ text: String) {
        for token in text.lowercased().split(whereSeparator: \.isWhitespace) {
            let parts = token.split(separator: ":", maxSplits: 1)
            if parts.count == 2, ["app", "host", "country", "port"].contains(String(parts[0])) {
                terms.append((String(parts[0]), String(parts[1])))
            } else {
                terms.append((nil, String(token)))
            }
        }
    }

    var isEmpty: Bool { terms.isEmpty }

    @MainActor
    func matches(_ summary: ConnectionSummary) -> Bool {
        guard !terms.isEmpty else { return true }
        let app = ProcessPresentation.name(for: summary.process).lowercased()
        let host = summary.endpoint.host.lowercased()
        let address = summary.remoteAddress?.description ?? ""
        let country = GeoService.shared.location(for: summary.remoteAddress)?.countryCode?.lowercased() ?? ""
        return terms.allSatisfy { term in
            switch term.key {
            case "app": app.contains(term.value) || (summary.process.signingID?.lowercased().contains(term.value) ?? false)
            case "host": host.contains(term.value) || address.contains(term.value)
            case "country": country == term.value
            case "port": String(summary.endpoint.port) == term.value
            default: app.contains(term.value) || host.contains(term.value) || address.contains(term.value) || country == term.value
            }
        }
    }
}
