import Foundation
import Security
import SquealerKit

/// Reads the signature of an app or executable on disk, so rules created in the editor or imported from a
/// path key on the same identity the extension sees at runtime.
enum CodeSignature {
    /// `thorough` validates every resource in the bundle; bulk scans skip that, since they only need the identity.
    static func identity(forPath path: String, thorough: Bool = true) -> ProcessIdentity? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        let bundle = isDirectory.boolValue ? Bundle(path: path) : nil
        let executable = bundle?.executablePath ?? path

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            return ProcessIdentity(path: executable, signer: .unsigned, bundlePath: bundle?.bundlePath)
        }
        var info: CFDictionary?
        SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        let information = info as? [String: Any] ?? [:]
        let signingID = information[kSecCodeInfoIdentifier as String] as? String
        let teamID = information[kSecCodeInfoTeamIdentifier as String] as? String

        let signer: Signer
        if signingID == nil {
            signer = .unsigned
        } else if SecStaticCodeCheckValidity(staticCode, validation(thorough), nil) != errSecSuccess {
            signer = .invalid
        } else if satisfies(staticCode, "anchor apple", thorough: thorough) {
            signer = .apple
        } else if satisfies(staticCode, "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists", thorough: thorough) {
            signer = .appStore
        } else if satisfies(staticCode, "anchor apple generic", thorough: thorough) {
            signer = .developerID
        } else {
            signer = .adHoc
        }
        return ProcessIdentity(
            path: executable,
            signingID: signingID,
            teamID: teamID,
            signer: signer,
            bundleID: bundle?.bundleIdentifier,
            bundlePath: bundle?.bundlePath
        )
    }

    private static func satisfies(_ code: SecStaticCode, _ text: String, thorough: Bool) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, validation(thorough), requirement) == errSecSuccess
    }

    private static func validation(_ thorough: Bool) -> SecCSFlags {
        thorough ? [] : SecCSFlags(rawValue: kSecCSBasicValidateOnly)
    }
}
