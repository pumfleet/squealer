import Foundation
@preconcurrency import Security
import SquealerKit
import Synchronization

/// Accepts connections from the Squealer app (verified by code signature) and fans events out to them.
final class XPCServer: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let listener = NSXPCListener(machServiceName: XPCConstants.machServiceName(ofExtensionAt: Bundle.main.bundleURL) ?? "")
    private final class Client: @unchecked Sendable {
        let connection: NSXPCConnection

        init(_ connection: NSXPCConnection) {
            self.connection = connection
        }
    }

    private let clients = Mutex<[ObjectIdentifier: Client]>([:])
    private unowned let engine: Engine

    init(engine: Engine) {
        self.engine = engine
        super.init()
        listener.delegate = self
        listener.setConnectionCodeSigningRequirement(
            XPCConstants.codeSigningRequirement(forAny: [XPCConstants.appBundleID, XPCConstants.cliIdentifier])
        )
    }

    func start() {
        listener.resume()
    }

    var hasClients: Bool {
        clients.withLock { !$0.isEmpty }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: EngineXPCProtocol.self)
        connection.remoteObjectInterface = NSXPCInterface(with: ClientXPCProtocol.self)

        // The listener only admits the app and the command-line tool. The tool never answers alerts, so it isn't
        // a client in that sense, and without root it may only read.
        guard Self.isApp(connection) else {
            connection.exportedObject = EngineService(engine: engine, readOnly: connection.effectiveUserIdentifier != 0)
            connection.resume()
            return true
        }
        connection.exportedObject = EngineService(engine: engine, readOnly: false)

        let id = ObjectIdentifier(connection)
        let remove: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            let isEmpty = self.clients.withLock { clients in
                clients.removeValue(forKey: id)
                return clients.isEmpty
            }
            if isEmpty {
                self.engine.queue.async { self.engine.clientsDidDisconnect() }
            }
        }
        connection.invalidationHandler = remove
        connection.interruptionHandler = remove
        let client = Client(connection)
        clients.withLock { $0[id] = client }
        connection.resume()
        log.info("Client connected (pid \(connection.processIdentifier))")
        return true
    }

    private static func isApp(_ connection: NSXPCConnection) -> Bool {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: connection.processIdentifier] as CFDictionary
        var requirement: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(XPCConstants.codeSigningRequirement(for: XPCConstants.appBundleID) as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    func broadcast(_ event: EngineEvent) {
        let clients = clients.withLock { Array($0.values) }
        guard !clients.isEmpty, let data = try? XPCCoding.encode(event) else { return }
        for client in clients {
            let proxy = client.connection.remoteObjectProxyWithErrorHandler { error in
                log.debug("Event delivery failed: \(error.localizedDescription, privacy: .public)")
            } as? ClientXPCProtocol
            proxy?.receive(data)
        }
    }
}

private final class EngineService: NSObject, EngineXPCProtocol, @unchecked Sendable {
    private unowned let engine: Engine
    private let readOnly: Bool

    init(engine: Engine, readOnly: Bool) {
        self.engine = engine
        self.readOnly = readOnly
    }

    func handle(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        guard let decoded = try? XPCCoding.decode(EngineRequest.self, from: request) else {
            reply((try? XPCCoding.encode(EngineResponse.failure("Malformed request"))) ?? Data())
            return
        }
        if readOnly, !decoded.isReadOnly {
            reply((try? XPCCoding.encode(EngineResponse.failure("Changing Squealer's settings from the command line requires sudo."))) ?? Data())
            return
        }
        Task { [engine] in
            let response = await engine.handle(decoded)
            reply((try? XPCCoding.encode(response)) ?? Data())
        }
    }
}
