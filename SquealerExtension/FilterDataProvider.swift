import Network
@preconcurrency import NetworkExtension
import SquealerKit

final class FilterDataProvider: NEFilterDataProvider {
    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        let everything = NENetworkRule(
            remoteNetworkEndpoint: nil,
            remotePrefix: 0,
            localNetworkEndpoint: nil,
            localPrefix: 0,
            protocol: .any,
            direction: .any
        )
        let settings = NEFilterSettings(rules: [NEFilterRule(networkRule: everything, action: .filterData)], defaultAction: .allow)
        Engine.shared.attach(self)
        nonisolated(unsafe) let completionHandler = completionHandler
        apply(settings) { error in
            if let error {
                log.fault("Couldn't apply filter settings: \(error.localizedDescription, privacy: .public)")
            } else {
                log.info("Filter started")
            }
            completionHandler(error)
        }
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        log.info("Filter stopped (reason \(reason.rawValue))")
        Engine.shared.detach()
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        Engine.shared.handleNewFlow(flow)
    }

    override func handleInboundData(from flow: NEFilterFlow, readBytesStartOffset offset: Int, readBytes: Data) -> NEFilterDataVerdict {
        Engine.shared.handleInboundData(from: flow, bytes: readBytes)
    }

    override func handle(_ report: NEFilterReport) {
        Engine.shared.handle(report)
    }
}
