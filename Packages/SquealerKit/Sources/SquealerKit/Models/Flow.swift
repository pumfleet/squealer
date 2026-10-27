import Foundation

/// Everything the engine knows about a connection at the moment it is decided.
public struct FlowContext: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var process: ProcessIdentity
    public var instance: ProcessInstance
    /// The helper that actually opened the socket when it differs from the responsible app.
    public var via: ProcessIdentity?
    public var direction: Direction
    public var transport: TransportProtocol
    public var remoteAddress: IPAddress?
    public var remotePort: UInt16
    public var remoteHostname: String?
    public var localPort: UInt16
    public var hostnameSource: HostnameSource
    public var timestamp: Date

    public init(
        id: UUID = UUID(),
        process: ProcessIdentity,
        instance: ProcessInstance,
        via: ProcessIdentity? = nil,
        direction: Direction,
        transport: TransportProtocol,
        remoteAddress: IPAddress?,
        remotePort: UInt16,
        remoteHostname: String? = nil,
        localPort: UInt16 = 0,
        hostnameSource: HostnameSource = .none,
        timestamp: Date = .now
    ) {
        self.id = id
        self.process = process
        self.instance = instance
        self.via = via
        self.direction = direction
        self.transport = transport
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.remoteHostname = remoteHostname.map(RemoteMatcher.normalize)
        self.localPort = localPort
        self.hostnameSource = hostnameSource
        self.timestamp = timestamp
    }

    /// What the UI should call the remote side.
    public var remoteDisplayName: String {
        remoteHostname ?? remoteAddress?.description ?? "unknown"
    }

    public var endpointKey: EndpointKey {
        EndpointKey(host: remoteDisplayName, port: remotePort, transport: transport, direction: direction)
    }
}

public enum HostnameSource: String, Codable, Sendable, Hashable {
    case flow
    case dns
    case reverse
    case none
}

/// Groups connections that the user would consider "the same" for alerting and statistics.
public struct EndpointKey: Hashable, Sendable, Codable {
    public var host: String
    public var port: UInt16
    public var transport: TransportProtocol
    public var direction: Direction

    public init(host: String, port: UInt16, transport: TransportProtocol, direction: Direction) {
        self.host = host
        self.port = port
        self.transport = transport
        self.direction = direction
    }
}
