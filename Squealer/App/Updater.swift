import Foundation
import Sparkle

/// Sparkle, enabled only when the build was configured with a feed URL and signing key.
@MainActor
final class Updater {
    static let shared = Updater()
    private let controller: SPUStandardUpdaterController?

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = info["SUFeedURL"] as? String ?? ""
        let key = info["SUPublicEDKey"] as? String ?? ""
        controller = feed.isEmpty || key.isEmpty ? nil : SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
