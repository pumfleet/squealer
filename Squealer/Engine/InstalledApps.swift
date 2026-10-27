import Foundation
import SquealerKit

/// Rules that let apps installed before Squealer keep connecting without asking, like LuLu's "allow installed
/// applications". Apple's own apps are skipped since a built-in default already covers them.
enum InstalledApps {
    static func trustRules() async -> [Rule] {
        await Task.detached(priority: .userInitiated) {
            var seen = Set<ProcessKey>()
            return applicationPaths().compactMap { path -> Rule? in
                guard let identity = CodeSignature.identity(forPath: path, thorough: false),
                      identity.signer.isTrusted, identity.signer != .apple,
                      seen.insert(identity.key).inserted else { return nil }
                return Rule(
                    process: .process(identity.key),
                    remote: .any,
                    action: .allow,
                    note: String(localized: "Installed before Squealer"),
                    origin: .user,
                    processName: identity.displayName,
                    processPath: path,
                    isApproved: false
                )
            }
        }.value
    }

    private static func applicationPaths() -> [String] {
        let fileManager = FileManager.default
        let roots = ["/Applications", "/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        var paths: [String] = []
        for root in roots {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries {
                let path = (root as NSString).appendingPathComponent(entry)
                if entry.hasSuffix(".app") {
                    paths.append(path)
                } else if let nested = try? fileManager.contentsOfDirectory(atPath: path) {
                    // Folders like /Applications/Setapp or vendor suites hold apps one level down.
                    paths += nested.filter { $0.hasSuffix(".app") }.map { (path as NSString).appendingPathComponent($0) }
                }
            }
        }
        return paths
    }
}
