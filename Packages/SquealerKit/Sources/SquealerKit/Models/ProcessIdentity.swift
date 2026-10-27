import Foundation

public enum Signer: String, Codable, Sendable, Hashable {
    case apple
    case appStore
    case developerID
    case adHoc
    case unsigned
    case invalid

    public var isTrusted: Bool {
        switch self {
        case .apple, .appStore, .developerID: true
        case .adHoc, .unsigned, .invalid: false
        }
    }
}

/// The stable key rules match against. Signed code is keyed by its signature so rules survive updates;
/// unsigned code falls back to its path.
public enum ProcessKey: Hashable, Sendable, Codable {
    case signed(teamID: String?, signingID: String)
    case path(String)

    public var signingID: String? {
        if case .signed(_, let id) = self { return id }
        return nil
    }
}

extension ProcessKey: CustomStringConvertible {
    public var description: String {
        switch self {
        case .signed(let team, let id): team.map { "\($0):\(id)" } ?? "apple:\(id)"
        case .path(let path): path
        }
    }
}

public struct ProcessIdentity: Hashable, Sendable, Codable {
    public var path: String
    public var signingID: String?
    public var teamID: String?
    public var signer: Signer
    public var cdhash: String?
    public var bundleID: String?
    /// Path of the enclosing `.app` bundle, if any; used for icons and display names.
    public var bundlePath: String?
    public var displayName: String

    public init(
        path: String,
        signingID: String? = nil,
        teamID: String? = nil,
        signer: Signer,
        cdhash: String? = nil,
        bundleID: String? = nil,
        bundlePath: String? = nil,
        displayName: String? = nil
    ) {
        self.path = path
        self.signingID = signingID
        self.teamID = teamID
        self.signer = signer
        self.cdhash = cdhash
        self.bundleID = bundleID
        self.bundlePath = bundlePath
        self.displayName = displayName ?? ProcessIdentity.defaultDisplayName(path: path, bundlePath: bundlePath, signingID: signingID)
    }

    public var key: ProcessKey {
        if signer.isTrusted, let signingID {
            return .signed(teamID: signer == .apple ? nil : teamID, signingID: signingID)
        }
        return .path(path)
    }

    public var isSystemExtension: Bool {
        path.hasPrefix("/Library/SystemExtensions/") && path.contains(".systemextension/")
    }

    public var executableName: String {
        (path as NSString).lastPathComponent
    }

    static func defaultDisplayName(path: String, bundlePath: String?, signingID: String? = nil) -> String {
        if let bundlePath {
            return ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        let components = (path as NSString).pathComponents
        let name = components.last ?? path
        let isVersion = name.first?.isNumber == true && name.allSatisfy { $0.isNumber || $0 == "." }
        // A signed tool installed as a bare version number is best named by its signature (`claude-code`).
        if isVersion, let signingID, let last = signingID.split(separator: ".").last, !last.isEmpty {
            return String(last)
        }
        // Self-updating CLIs often install as `<tool>/versions/1.2.3`; name them after the tool.
        if isVersion, components.count >= 3 {
            let parent = components[components.count - 2]
            let tool = parent == "versions" ? components[components.count - 3] : parent
            return "\(tool) \(name)"
        }
        return name
    }
}

/// A live process: identity plus the instance details needed for "until quit" rules.
public struct ProcessInstance: Hashable, Sendable, Codable {
    public var pid: Int32
    /// The audit token's PID version, which changes on every exec and so disambiguates PID reuse.
    public var generation: UInt32

    public init(pid: Int32, generation: UInt32) {
        self.pid = pid
        self.generation = generation
    }
}
