import Foundation
import SquealerKit
import Synchronization

/// Folds per-flow events into per-(process, endpoint) summaries, live rates and history deltas.
final class TrafficAggregator: Sendable {
    private struct FlowRecord {
        var summaryID: ConnectionSummary.ID
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
        var lastUpdate: Date
        var log: ConnectionLogEntry
    }

    private struct HistoryKey: Hashable {
        var process: String
        var host: String
    }

    private struct State {
        var summaries: [ConnectionSummary.ID: ConnectionSummary] = [:]
        var flows: [UUID: FlowRecord] = [:]
        var changed: Set<ConnectionSummary.ID> = []
        var intervalBytes: [ConnectionSummary.ID: (in: UInt64, out: UInt64)] = [:]
        var history: [HistoryKey: Store.TrafficDelta] = [:]
        var log: [ConnectionLogEntry] = []
        var lastTick = Date()
    }

    private let state = Mutex(State())
    private static let summaryLifetime: TimeInterval = 24 * 3_600
    private static let staleFlowLifetime: TimeInterval = 6 * 3_600

    func recordNewFlow(id: UUID, context: FlowContext, verdict: VerdictInfo) {
        let summaryID = ConnectionSummary.ID(process: context.process.key, via: context.via?.key, endpoint: context.endpointKey)
        let allowed = verdict.action == .allow && verdict.kind != .pending
        state.withLock { state in
            var summary = state.summaries[summaryID] ?? ConnectionSummary(
                id: summaryID,
                process: context.process,
                via: context.via,
                remoteAddress: context.remoteAddress,
                hostnameSource: context.hostnameSource,
                lastVerdict: verdict,
                firstSeen: context.timestamp
            )
            summary.process = context.process
            summary.remoteAddress = context.remoteAddress ?? summary.remoteAddress
            summary.lastVerdict = verdict
            summary.lastSeen = context.timestamp
            if verdict.kind != .pending {
                summary.totalFlows += 1
                let entry = Self.logEntry(for: context, verdict: verdict)
                if allowed {
                    summary.activeFlows += 1
                    state.flows[id] = FlowRecord(summaryID: summaryID, lastUpdate: context.timestamp, log: entry)
                } else {
                    summary.deniedFlows += 1
                    state.log.append(entry)
                }
                let key = HistoryKey(process: summaryID.process.description, host: summaryID.endpoint.host)
                state.history[key, default: Store.TrafficDelta(process: key.process, host: key.host)].connections += 1
                if !allowed {
                    state.history[key, default: Store.TrafficDelta(process: key.process, host: key.host)].denied += 1
                }
            }
            state.summaries[summaryID] = summary
            state.changed.insert(summaryID)
        }
    }

    /// Accepts either cumulative or per-report byte counts: a count lower than the previous one is treated as
    /// a fresh increment.
    func recordBytes(flowID: UUID, inbound: UInt64, outbound: UInt64, closed: Bool, now: Date = .now) {
        state.withLock { state in
            guard var flow = state.flows[flowID] else { return }
            let deltaIn = inbound >= flow.bytesIn ? inbound - flow.bytesIn : inbound
            let deltaOut = outbound >= flow.bytesOut ? outbound - flow.bytesOut : outbound
            flow.bytesIn = inbound
            flow.bytesOut = outbound
            flow.lastUpdate = now

            if var summary = state.summaries[flow.summaryID] {
                summary.bytesIn += deltaIn
                summary.bytesOut += deltaOut
                summary.lastSeen = now
                if closed { summary.activeFlows = max(0, summary.activeFlows - 1) }
                state.summaries[flow.summaryID] = summary
                state.changed.insert(flow.summaryID)

                let key = HistoryKey(process: flow.summaryID.process.description, host: flow.summaryID.endpoint.host)
                state.history[key, default: Store.TrafficDelta(process: key.process, host: key.host)].bytesIn += deltaIn
                state.history[key, default: Store.TrafficDelta(process: key.process, host: key.host)].bytesOut += deltaOut
            }
            let interval = state.intervalBytes[flow.summaryID] ?? (0, 0)
            state.intervalBytes[flow.summaryID] = (interval.in + deltaIn, interval.out + deltaOut)

            if closed {
                var entry = flow.log
                entry.end = now
                entry.bytesIn = flow.bytesIn
                entry.bytesOut = flow.bytesOut
                state.log.append(entry)
                state.flows.removeValue(forKey: flowID)
            } else {
                state.flows[flowID] = flow
            }
        }
    }

    /// Computes rates since the previous tick and returns the summaries that changed.
    func tick(now: Date = .now) -> TrafficUpdate? {
        state.withLock { state in
            let elapsed = max(now.timeIntervalSince(state.lastTick), 0.001)
            state.lastTick = now
            var totalIn = 0.0
            var totalOut = 0.0

            for (id, summary) in state.summaries where summary.rateIn > 0 || summary.rateOut > 0 {
                if state.intervalBytes[id] == nil {
                    state.summaries[id]?.rateIn = 0
                    state.summaries[id]?.rateOut = 0
                    state.changed.insert(id)
                }
            }
            for (id, bytes) in state.intervalBytes {
                let rateIn = Double(bytes.in) / elapsed
                let rateOut = Double(bytes.out) / elapsed
                state.summaries[id]?.rateIn = rateIn
                state.summaries[id]?.rateOut = rateOut
                totalIn += rateIn
                totalOut += rateOut
            }
            state.intervalBytes.removeAll(keepingCapacity: true)

            let changed = state.changed.compactMap { state.summaries[$0] }
            state.changed.removeAll(keepingCapacity: true)
            return TrafficUpdate(timestamp: now, connections: changed, totalRateIn: totalIn, totalRateOut: totalOut)
        }
    }

    func drainLog() -> [ConnectionLogEntry] {
        state.withLock { state in
            defer { state.log.removeAll(keepingCapacity: true) }
            return state.log
        }
    }

    private static func logEntry(for context: FlowContext, verdict: VerdictInfo) -> ConnectionLogEntry {
        ConnectionLogEntry(
            start: context.timestamp,
            end: verdict.action == .deny ? context.timestamp : nil,
            process: context.process.key,
            processName: context.process.displayName,
            processPath: context.process.bundlePath ?? context.process.path,
            viaName: context.via?.displayName,
            host: context.remoteDisplayName,
            address: context.remoteAddress,
            port: context.direction == .inbound ? context.localPort : context.remotePort,
            transport: context.transport,
            direction: context.direction,
            verdict: verdict,
            bytesIn: 0,
            bytesOut: 0
        )
    }

    func drainHistory() -> [Store.TrafficDelta] {
        state.withLock { state in
            defer { state.history.removeAll(keepingCapacity: true) }
            return Array(state.history.values)
        }
    }

    func allSummaries() -> [ConnectionSummary] {
        state.withLock { Array($0.summaries.values) }
    }

    func prune(now: Date = .now) {
        state.withLock { state in
            state.flows = state.flows.filter { now.timeIntervalSince($0.value.lastUpdate) < Self.staleFlowLifetime }
            var active: [ConnectionSummary.ID: Int] = [:]
            for flow in state.flows.values { active[flow.summaryID, default: 0] += 1 }
            state.summaries = state.summaries.filter { id, summary in
                active[id] != nil || now.timeIntervalSince(summary.lastSeen) < Self.summaryLifetime
            }
            for id in state.summaries.keys {
                state.summaries[id]?.activeFlows = active[id] ?? 0
            }
        }
    }

    func clear() {
        state.withLock { state in
            state.summaries.removeAll()
            state.history.removeAll()
            state.changed.removeAll()
        }
    }
}
