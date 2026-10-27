import Foundation
import os
import SquealerKit
import Synchronization

/// Where the app's data comes from: the real system extension, or the demo generator used for previews,
/// screenshots and UI work without a signed extension.
protocol EngineBackend: AnyObject, Sendable {
    var events: AsyncStream<EngineEvent> { get }
    var connectionChanges: AsyncStream<Bool> { get }
    func connect()
    func send(_ request: EngineRequest) async throws -> EngineResponse
}

enum EngineClientError: LocalizedError {
    case notConnected
    case malformedResponse
    case engine(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "Squealer's network extension isn't running."
        case .malformedResponse: "The network extension sent an unexpected response."
        case .engine(let message): message
        }
    }
}

final class EngineClient: NSObject, EngineBackend, ClientXPCProtocol, @unchecked Sendable {
    let events: AsyncStream<EngineEvent>
    let connectionChanges: AsyncStream<Bool>
    private let eventContinuation: AsyncStream<EngineEvent>.Continuation
    private let connectionContinuation: AsyncStream<Bool>.Continuation
    private let lock = NSLock()
    private var currentConnection: NSXPCConnection?
    private let logger = Logger(subsystem: XPCConstants.logSubsystem, category: "client")

    override init() {
        (events, eventContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(512))
        (connectionChanges, connectionContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        super.init()
    }

    func connect() {
        guard lock.withLock({ currentConnection == nil }) else {
            connectionContinuation.yield(true)
            return
        }
        guard let serviceName = XPCConstants.machServiceName(ofExtensionAt: XPCConstants.bundledExtension(inApp: Bundle.main.bundleURL)) else {
            logger.fault("The bundled extension has no XPC service name")
            return
        }
        let connection = NSXPCConnection(machServiceName: serviceName, options: .privileged)
        connection.setCodeSigningRequirement(XPCConstants.codeSigningRequirement(for: XPCConstants.extensionBundleID))
        connection.remoteObjectInterface = NSXPCInterface(with: EngineXPCProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: ClientXPCProtocol.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self] in self?.disconnected() }
        connection.interruptionHandler = { [weak self] in self?.disconnected() }
        lock.withLock { currentConnection = connection }
        connection.resume()
        connectionContinuation.yield(true)
    }

    private func disconnected() {
        let existing = lock.withLock {
            defer { currentConnection = nil }
            return currentConnection
        }
        guard existing != nil else { return }
        existing?.invalidate()
        logger.info("Disconnected from engine")
        connectionContinuation.yield(false)
    }

    func send(_ request: EngineRequest) async throws -> EngineResponse {
        guard let connection = lock.withLock({ currentConnection }) else { throw EngineClientError.notConnected }
        let payload = try XPCCoding.encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            let once = Mutex(false)
            let finish: @Sendable (Result<EngineResponse, Error>) -> Void = { result in
                guard once.withLock({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(with: result)
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                finish(.failure(error))
            } as? EngineXPCProtocol
            guard let proxy else {
                finish(.failure(EngineClientError.notConnected))
                return
            }
            proxy.handle(payload) { data in
                guard let response = try? XPCCoding.decode(EngineResponse.self, from: data) else {
                    finish(.failure(EngineClientError.malformedResponse))
                    return
                }
                if case .failure(let message) = response {
                    finish(.failure(EngineClientError.engine(message)))
                } else {
                    finish(.success(response))
                }
            }
        }
    }

    func receive(_ event: Data) {
        guard let decoded = try? XPCCoding.decode(EngineEvent.self, from: event) else { return }
        eventContinuation.yield(decoded)
    }
}
