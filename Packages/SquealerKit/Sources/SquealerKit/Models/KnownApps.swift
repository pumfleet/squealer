import Foundation

public enum KnownApps {
    private static let browserSigningPrefixes = [
        "com.google.Chrome", "com.apple.Safari", "com.apple.WebKit.Networking", "org.mozilla.firefox",
        "org.mozilla.nightly", "company.thebrowser.Browser", "com.microsoft.edgemac", "com.brave.Browser",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "app.zen-browser.zen", "org.chromium.Chromium",
    ]

    /// Browsers legitimately connect to every site the user visits, so per-server alerts are just noise.
    public static func isWebBrowser(_ process: ProcessIdentity) -> Bool {
        guard let id = process.signingID ?? process.bundleID else { return false }
        return browserSigningPrefixes.contains { id == $0 || id.hasPrefix($0 + ".") }
    }
}
