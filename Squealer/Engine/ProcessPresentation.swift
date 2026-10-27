import AppKit
import SquealerKit

/// Friendly names and icons for processes. The extension only knows paths and signatures; the app can read
/// bundles and ask Launch Services.
@MainActor
enum ProcessPresentation {
    private static var icons: [String: NSImage] = [:]
    private static var names: [String: String] = [:]

    static func icon(for process: ProcessIdentity) -> NSImage {
        icon(forPath: process.bundlePath.flatMap(outermostApp) ?? process.bundlePath ?? process.path)
    }

    static func icon(forPath path: String) -> NSImage {
        if let cached = icons[path] { return cached }
        let icon: NSImage
        if FileManager.default.fileExists(atPath: path) {
            icon = NSWorkspace.shared.icon(forFile: path)
        } else {
            icon = NSWorkspace.shared.icon(for: .unixExecutable)
        }
        icons[path] = icon
        return icon
    }

    static func name(for process: ProcessIdentity) -> String {
        let path = process.bundlePath ?? process.path
        if let cached = names[path] { return cached }
        var name = process.displayName
        if let bundlePath = process.bundlePath, let bundle = Bundle(path: bundlePath) {
            name = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
                ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
                ?? bundle.infoDictionary?["CFBundleName"] as? String
                ?? name
        }
        names[path] = name
        return name
    }

    /// The app a helper belongs to, e.g. `Google Chrome.app` for `Google Chrome Helper.app`.
    static func owningApp(for process: ProcessIdentity) -> String? {
        process.bundlePath.flatMap(outermostApp).flatMap { $0 == process.bundlePath ? nil : $0 }
    }

    private static func outermostApp(_ path: String) -> String? {
        var components: [String] = []
        for component in (path as NSString).pathComponents {
            components.append(component)
            if component.hasSuffix(".app") {
                return NSString.path(withComponents: components)
            }
        }
        return nil
    }

    static func signerDescription(_ process: ProcessIdentity) -> String {
        switch process.signer {
        case .apple: String(localized: "Apple")
        case .appStore: String(localized: "App Store")
        case .developerID: process.teamID.map { String(localized: "Developer \($0)") } ?? String(localized: "Identified developer")
        case .adHoc: String(localized: "Ad-hoc signed")
        case .unsigned: String(localized: "Unsigned")
        case .invalid: String(localized: "Invalid signature")
        }
    }
}
