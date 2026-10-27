import CoreGraphics
import Foundation
import LocalAuthentication
import SquealerKit

enum Session {
    /// The current boot and login session, which "until restart" and "until logout" rules are tied to.
    static var current: SessionInfo {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &time, &size, nil, 0)
        let boot = Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000)
        let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any]
        let session = (dictionary?["kCGSSessionIDKey"] as? NSNumber)?.stringValue ?? "unknown"
        return SessionInfo(bootTime: boot, loginSession: "\(session)-\(Int(boot.timeIntervalSince1970))")
    }
}

enum Authentication {
    static func request(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = String(localized: "Use Password")
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}
