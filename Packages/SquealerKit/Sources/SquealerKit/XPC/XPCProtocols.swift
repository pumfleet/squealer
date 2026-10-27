import Foundation

/// Implemented by the system extension; called by the app.
@objc public protocol EngineXPCProtocol {
    func handle(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}

/// Implemented by the app; called by the system extension.
@objc public protocol ClientXPCProtocol {
    func receive(_ event: Data)
}

public enum XPCConstants {
    public static let teamID = "U6P67B4375"
    public static let appBundleID = "com.fusial.squealer"
    public static let extensionBundleID = "com.fusial.squealer.extension"
    public static let cliIdentifier = "com.fusial.squealer.cli"
    /// Each extension build has its own endpoint (the build number is appended in its Info.plist). Reusing one
    /// name across builds races in launchd when an update replaces the running extension: the new build can't
    /// register the name while the old one still holds it, and stays unreachable until a reboot.
    public static func machServiceName(ofExtensionAt url: URL) -> String? {
        let info = Bundle(url: url)?.infoDictionary ?? NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        return (info?["NetworkExtension"] as? [String: Any])?["NEMachServiceName"] as? String
    }

    /// The extension bundled inside the Squealer app at `appURL`.
    public static func bundledExtension(inApp appURL: URL) -> URL {
        appURL.appendingPathComponent("Contents/Library/SystemExtensions/\(extensionBundleID).systemextension")
    }
    public static let logSubsystem = "com.fusial.squealer"

    public static func codeSigningRequirement(for identifier: String) -> String {
        codeSigningRequirement(forAny: [identifier])
    }

    public static func codeSigningRequirement(forAny identifiers: [String]) -> String {
        let clause = identifiers.map { "identifier \"\($0)\"" }.joined(separator: " or ")
        return "anchor apple generic and (\(clause)) and certificate leaf[subject.OU] = \"\(teamID)\""
    }
}

public enum XPCCoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try PropertyListDecoder().decode(type, from: data)
    }
}
