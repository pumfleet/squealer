import Foundation

/// Where licensing plugs in once pricing is decided. Until then everything is unlocked; a real provider
/// (signed license keys, a trial clock) replaces `Licensing.provider` without touching the rest of the app.
enum LicenseStatus: Equatable {
    case unlocked
    case trial(daysLeft: Int)
    case expired
}

protocol LicenseProvider: Sendable {
    var status: LicenseStatus { get }
}

struct UnlockedLicense: LicenseProvider {
    var status: LicenseStatus { .unlocked }
}

enum Licensing {
    static let provider: any LicenseProvider = UnlockedLicense()
}
