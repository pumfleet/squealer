import Foundation
@preconcurrency import NetworkExtension
import SquealerKit
import Synchronization

/// NEFilterFlow is only ever handed back to `resumeFlow`, which is safe from any thread.
final class FlowBox: @unchecked Sendable {
    let flow: NEFilterFlow
    let context: FlowContext

    init(_ flow: NEFilterFlow, context: FlowContext) {
        self.flow = flow
        self.context = context
    }
}

/// Holds paused flows while the user decides. Each process shows at most one alert at a time; its other
/// connections wait behind it and are re-evaluated once the user answers, since the answer often covers them.
final class FlowCoordinator: Sendable {
    private struct AlertGroup {
        var alert: ConnectionAlert
        var flows: [FlowBox]
    }

    private struct State {
        var alerts: [UUID: AlertGroup] = [:]
        var alertByProcess: [ProcessKey: UUID] = [:]
        var waiting: [ProcessKey: [FlowBox]] = [:]
    }

    enum Resolution: Sendable {
        case verdict(Verdict)
        case later
    }

    private let state = Mutex(State())
    private unowned let engine: Engine

    init(engine: Engine) {
        self.engine = engine
    }

    var pendingAlerts: [ConnectionAlert] {
        state.withLock { $0.alerts.values.map(\.alert).sorted { $0.firstSeen < $1.firstSeen } }
    }

    func enqueue(_ box: FlowBox, timeout: TimeInterval) {
        let processKey = box.context.process.key
        let event: EngineEvent? = state.withLock { state in
            if let alertID = state.alertByProcess[processKey], var group = state.alerts[alertID] {
                if group.alert.flow.endpointKey == box.context.endpointKey {
                    group.flows.append(box)
                    group.alert.attempts += 1
                    state.alerts[alertID] = group
                    return .alert(group.alert)
                }
                state.waiting[processKey, default: []].append(box)
                return nil
            }
            let alert = Self.makeAlert(for: box, timeout: timeout)
            state.alerts[alert.id] = AlertGroup(alert: alert, flows: [box])
            state.alertByProcess[processKey] = alert.id
            return .alert(alert)
        }
        if let event {
            engine.broadcast(event)
            if case .alert(let alert) = event, alert.attempts == 1 {
                scheduleTimeout(for: alert)
            }
        }
    }

    func resolve(alertID: UUID, with resolution: Resolution) {
        guard let group = state.withLock({ state -> AlertGroup? in
            guard let group = state.alerts.removeValue(forKey: alertID) else { return nil }
            state.alertByProcess.removeValue(forKey: group.alert.flow.process.key)
            return group
        }) else { return }

        engine.broadcast(.alertWithdrawn(alertID))
        for box in group.flows {
            switch resolution {
            case .verdict(let verdict):
                engine.resume(box, verdict: verdict)
            case .later:
                engine.resume(box, verdict: Verdict(action: .allow, reason: .userOnce))
            }
        }
        if case .later = resolution {
            engine.addReview(group.alert.flow, action: .allow, reason: .once, attempts: group.alert.attempts)
        }
        reevaluate()
    }

    /// Re-decides every paused flow against the current rules: resolves what the rules now cover, withdraws
    /// alerts that became moot and raises the next alert for processes that still have waiting connections.
    func reevaluate() {
        let rules = engine.currentRules
        var resolved: [(FlowBox, Verdict)] = []
        var withdrawn: [UUID] = []
        var raised: [ConnectionAlert] = []
        let timeout = rules.settings.alertTimeout

        state.withLock { state in
            for (id, var group) in state.alerts {
                var stillPending: [FlowBox] = []
                for box in group.flows {
                    if case .decided(let verdict) = rules.decide(box.context) {
                        resolved.append((box, verdict))
                    } else {
                        stillPending.append(box)
                    }
                }
                if stillPending.isEmpty {
                    state.alerts.removeValue(forKey: id)
                    state.alertByProcess.removeValue(forKey: group.alert.flow.process.key)
                    withdrawn.append(id)
                } else {
                    group.flows = stillPending
                    state.alerts[id] = group
                }
            }

            for (processKey, boxes) in state.waiting {
                var remaining: [FlowBox] = []
                for box in boxes {
                    if case .decided(let verdict) = rules.decide(box.context) {
                        resolved.append((box, verdict))
                        continue
                    }
                    if let alertID = state.alertByProcess[processKey], var group = state.alerts[alertID] {
                        if group.alert.flow.endpointKey == box.context.endpointKey {
                            group.flows.append(box)
                            group.alert.attempts += 1
                            state.alerts[alertID] = group
                        } else {
                            remaining.append(box)
                        }
                    } else {
                        let alert = Self.makeAlert(for: box, timeout: timeout)
                        state.alerts[alert.id] = AlertGroup(alert: alert, flows: [box])
                        state.alertByProcess[processKey] = alert.id
                        raised.append(alert)
                    }
                }
                state.waiting[processKey] = remaining.isEmpty ? nil : remaining
            }
        }

        for (box, verdict) in resolved {
            engine.resume(box, verdict: verdict)
        }
        for id in withdrawn {
            engine.broadcast(.alertWithdrawn(id))
        }
        for alert in raised {
            engine.broadcast(.alert(alert))
            scheduleTimeout(for: alert)
        }
    }

    /// Releases everything with a fixed verdict, e.g. when the last app client disconnects.
    func releaseAll(action: RuleAction, reason: VerdictInfo.Kind) {
        let (groups, waiting) = state.withLock { state in
            defer { state = State() }
            return (Array(state.alerts.values), state.waiting.values.flatMap { $0 })
        }
        let verdictReason: VerdictReason = reason == .timeout ? .timeout : .noClient
        for group in groups {
            engine.broadcast(.alertWithdrawn(group.alert.id))
            engine.addReview(group.alert.flow, action: action, reason: reason, attempts: group.alert.attempts)
            group.flows.forEach { engine.resume($0, verdict: Verdict(action: action, reason: verdictReason)) }
        }
        for box in waiting {
            engine.addReview(box.context, action: action, reason: reason, attempts: 1)
            engine.resume(box, verdict: Verdict(action: action, reason: verdictReason))
        }
    }

    /// Drops connections whose process has exited; there's nobody left to resume them for.
    func reap() {
        let (dead, withdrawn): ([FlowBox], [UUID]) = state.withLock { state in
            var dead: [FlowBox] = []
            var withdrawn: [UUID] = []
            for (id, group) in state.alerts where !ProcessResolver.isAlive(group.alert.flow.instance) {
                dead += group.flows
                withdrawn.append(id)
                state.alerts.removeValue(forKey: id)
                state.alertByProcess.removeValue(forKey: group.alert.flow.process.key)
            }
            for (key, boxes) in state.waiting {
                let alive = boxes.filter { ProcessResolver.isAlive($0.context.instance) }
                dead += boxes.filter { !ProcessResolver.isAlive($0.context.instance) }
                state.waiting[key] = alive.isEmpty ? nil : alive
            }
            return (dead, withdrawn)
        }
        for box in dead {
            engine.resume(box, verdict: Verdict(action: .deny, reason: .noClient))
        }
        for id in withdrawn {
            engine.broadcast(.alertWithdrawn(id))
        }
        if !dead.isEmpty {
            reevaluate()
        }
    }

    private static func makeAlert(for box: FlowBox, timeout: TimeInterval) -> ConnectionAlert {
        let now = Date()
        return ConnectionAlert(
            flow: box.context,
            firstSeen: now,
            deadline: timeout > 0 ? now + timeout : .distantFuture
        )
    }

    private func scheduleTimeout(for alert: ConnectionAlert) {
        guard alert.deadline != .distantFuture else { return }
        let delay = max(0, alert.deadline.timeIntervalSinceNow)
        engine.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.state.withLock({ $0.alerts[alert.id] != nil }) else { return }
            let action = self.engine.currentRules.settings.alertTimeoutAction == .allow ? RuleAction.allow : .deny
            self.engine.addReview(alert.flow, action: action, reason: .timeout, attempts: alert.attempts)
            self.resolve(alertID: alert.id, with: .verdict(Verdict(action: action, reason: .timeout)))
        }
    }
}
