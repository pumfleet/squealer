import Darwin
import Foundation
@preconcurrency import Security
import SquealerKit
import Synchronization

struct ResolvedProcess: Sendable {
    var identity: ProcessIdentity
    var instance: ProcessInstance
}

/// Turns audit tokens into code-signing identities. Signature checks are expensive, so results are cached
/// per token (which includes the PID version, so a recycled PID never hits a stale entry).
final class ProcessResolver: Sendable {
    private let cache = Mutex<[Data: ResolvedProcess]>([:])
    private let parents = Mutex<[String: ProcessIdentity?]>([:])
    private let capacity = 4_096

    nonisolated(unsafe) private static let appleRequirement = requirement("anchor apple")
    nonisolated(unsafe) private static let appStoreRequirement = requirement("anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists")
    nonisolated(unsafe) private static let developerIDRequirement = requirement(
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    )
    nonisolated(unsafe) private static let appleIssuedRequirement = requirement("anchor apple generic")

    private static func requirement(_ text: String) -> SecRequirement? {
        var requirement: SecRequirement?
        SecRequirementCreateWithString(text as CFString, [], &requirement)
        return requirement
    }

    func resolve(auditToken: Data) -> ResolvedProcess? {
        if let cached = cache.withLock({ $0[auditToken] }) {
            return cached
        }
        guard let token = Self.auditToken(from: auditToken) else { return nil }
        let instance = ProcessInstance(pid: Int32(bitPattern: token.val.5), generation: token.val.7)
        let identity = Self.identity(auditToken: auditToken, pid: instance.pid)
        let resolved = ResolvedProcess(identity: identity, instance: instance)
        cache.withLock { cache in
            if cache.count >= capacity { cache.removeAll(keepingCapacity: true) }
            cache[auditToken] = resolved
        }
        return resolved
    }

    /// The app bundle a helper lives inside (e.g. `Wispr Flow.app` for `Wispr Flow Helper`), but only when it
    /// carries the same team's signature, so a foreign binary dropped into a bundle can't borrow its rules.
    func parentApp(of identity: ProcessIdentity) -> ProcessIdentity? {
        guard identity.signer.isTrusted, let helperBundle = identity.bundlePath,
              let outer = Self.outermostApp(containing: identity.path), outer != helperBundle else { return nil }
        if let cached = parents.withLock({ $0[outer] }) {
            return Self.sameDeveloper(cached, identity) ? cached : nil
        }
        let parent = Self.staticIdentity(ofBundle: outer)
        parents.withLock { $0[outer] = parent }
        return Self.sameDeveloper(parent, identity) ? parent : nil
    }

    private static func sameDeveloper(_ parent: ProcessIdentity?, _ helper: ProcessIdentity) -> Bool {
        guard let parent, parent.signer.isTrusted else { return false }
        if parent.signer == .apple || helper.signer == .apple { return parent.signer == helper.signer }
        return parent.teamID != nil && parent.teamID == helper.teamID
    }

    static func outermostApp(containing path: String) -> String? {
        var components: [String] = []
        for component in (path as NSString).pathComponents {
            components.append(component)
            if component.hasSuffix(".app") { return NSString.path(withComponents: components) }
        }
        return nil
    }

    /// The signature of an executable or bundle on disk.
    static func staticIdentity(atPath path: String) -> ProcessIdentity? {
        staticIdentity(ofBundle: path)
    }

    private static func staticIdentity(ofBundle path: String) -> ProcessIdentity? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let information = info as? [String: Any],
              let signingID = information[kSecCodeInfoIdentifier as String] as? String else { return nil }
        let teamID = information[kSecCodeInfoTeamIdentifier as String] as? String
        let signer: Signer
        if staticCheck(staticCode, appleRequirement) {
            signer = .apple
        } else if staticCheck(staticCode, appStoreRequirement) {
            signer = .appStore
        } else if staticCheck(staticCode, appleIssuedRequirement) {
            signer = .developerID
        } else {
            return nil
        }
        let executable = (information[kSecCodeInfoMainExecutable as String] as? URL)?.path ?? path
        let bundlePath = path.hasSuffix(".app") || path.hasSuffix(".appex") || path.hasSuffix(".xpc") ? path : enclosingBundle(of: executable)
        return ProcessIdentity(path: executable, signingID: signingID, teamID: teamID, signer: signer, bundlePath: bundlePath)
    }

    private static func staticCheck(_ code: SecStaticCode, _ requirement: SecRequirement?) -> Bool {
        guard let requirement else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSBasicValidateOnly), requirement) == errSecSuccess
    }

    static func auditToken(from data: Data) -> audit_token_t? {
        guard data.count == MemoryLayout<audit_token_t>.size else { return nil }
        return data.withUnsafeBytes { $0.loadUnaligned(as: audit_token_t.self) }
    }

    /// `kill(pid, 0)` reports ESRCH only when no such process exists; EPERM still means it's alive.
    static func isAlive(_ instance: ProcessInstance) -> Bool {
        kill(instance.pid, 0) == 0 || errno != ESRCH
    }

    private static func identity(auditToken: Data, pid: Int32) -> ProcessIdentity {
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: auditToken] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else {
            return ProcessIdentity(path: pidPath(pid) ?? "pid \(pid)", signer: .unsigned)
        }

        var path = pidPath(pid)
        var staticCode: SecStaticCode?
        var information: [String: Any] = [:]
        if SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode {
            var url: CFURL?
            if path == nil, SecCodeCopyPath(staticCode, [], &url) == errSecSuccess, let url {
                path = (url as URL).path
            }
            var info: CFDictionary?
            if SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess {
                information = info as? [String: Any] ?? [:]
            }
        }

        let resolvedPath = path ?? "pid \(pid)"
        let signingID = information[kSecCodeInfoIdentifier as String] as? String
        let teamID = information[kSecCodeInfoTeamIdentifier as String] as? String
        let cdhash = (information[kSecCodeInfoUnique as String] as? Data)?.map { String(format: "%02x", $0) }.joined()
        let flags = (information[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0

        let signer: Signer
        if signingID == nil {
            signer = .unsigned
        } else if SecCodeCheckValidity(code, [], nil) != errSecSuccess {
            signer = .invalid
        } else if check(code, appleRequirement) {
            signer = .apple
        } else if check(code, appStoreRequirement) {
            signer = .appStore
        } else if check(code, developerIDRequirement) || check(code, appleIssuedRequirement) {
            signer = .developerID
        } else {
            signer = flags & 0x2 != 0 ? .adHoc : .invalid
        }

        let bundlePath = enclosingBundle(of: resolvedPath)
        return ProcessIdentity(
            path: resolvedPath,
            signingID: signingID,
            teamID: teamID,
            signer: signer,
            cdhash: cdhash,
            bundleID: bundlePath.flatMap { Bundle(path: $0)?.bundleIdentifier },
            bundlePath: bundlePath
        )
    }

    private static func check(_ code: SecCode, _ requirement: SecRequirement?) -> Bool {
        guard let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    private static func pidPath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    /// The innermost bundle (`.app`, `.appex`, `.xpc`, …) containing the executable.
    static func enclosingBundle(of path: String) -> String? {
        let extensions: Set<String> = ["app", "appex", "xpc", "systemextension", "framework", "bundle"]
        var components = (path as NSString).pathComponents
        while components.count > 1 {
            components.removeLast()
            let candidate = NSString.path(withComponents: components)
            if extensions.contains((candidate as NSString).pathExtension.lowercased()) {
                return candidate
            }
        }
        return nil
    }
}
