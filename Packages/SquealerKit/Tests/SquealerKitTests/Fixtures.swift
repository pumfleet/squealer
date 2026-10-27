import Foundation
@testable import SquealerKit

enum Fixtures {
    static let spotify = ProcessIdentity(
        path: "/Applications/Spotify.app/Contents/MacOS/Spotify",
        signingID: "com.spotify.client",
        teamID: "2FNC3A47ZF",
        signer: .developerID,
        bundleID: "com.spotify.client",
        bundlePath: "/Applications/Spotify.app"
    )

    static let safari = ProcessIdentity(
        path: "/Applications/Safari.app/Contents/MacOS/Safari",
        signingID: "com.apple.Safari",
        signer: .apple,
        bundlePath: "/Applications/Safari.app"
    )

    static let webkitNetworking = ProcessIdentity(
        path: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking",
        signingID: "com.apple.WebKit.Networking",
        signer: .apple
    )

    static let unsigned = ProcessIdentity(path: "/usr/local/bin/tool", signer: .unsigned)

    static let instance = ProcessInstance(pid: 100, generation: 1)

    static func flow(
        _ process: ProcessIdentity = spotify,
        via: ProcessIdentity? = nil,
        host: String? = "api.spotify.com",
        address: String = "35.186.224.25",
        port: UInt16 = 443,
        transport: TransportProtocol = .tcp,
        direction: Direction = .outbound,
        instance: ProcessInstance = instance
    ) -> FlowContext {
        FlowContext(
            process: process,
            instance: instance,
            via: via,
            direction: direction,
            transport: transport,
            remoteAddress: IPAddress(address),
            remotePort: port,
            remoteHostname: host
        )
    }

    static func rule(
        _ process: ProcessIdentity? = spotify,
        remote: RemoteMatcher = .any,
        ports: PortMatcher = .any,
        action: RuleAction,
        direction: Direction = .outbound,
        lifetime: RuleLifetime = .forever,
        profileID: UUID? = nil
    ) -> Rule {
        Rule(
            process: process.map { .process($0.key) } ?? .any,
            direction: direction,
            remote: remote,
            ports: ports,
            action: action,
            lifetime: lifetime,
            profileID: profileID
        )
    }
}
