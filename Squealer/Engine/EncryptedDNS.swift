import Foundation
import NetworkExtension
import Observation
import os
import SquealerKit

/// System-wide DNS over HTTPS through NEDNSSettingsManager. macOS lists the configuration under
/// System Settings › Network › Filters, where the user has to switch it on.
@MainActor @Observable
final class EncryptedDNS {
    struct Provider: Identifiable, Hashable {
        var id: String
        var name: String
        var detail: String
        var url: String
        var servers: [String]

        static let all: [Provider] = [
            Provider(id: "cloudflare", name: "Cloudflare", detail: String(localized: "Fast and privacy-focused."), url: "https://cloudflare-dns.com/dns-query", servers: ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"]),
            Provider(id: "cloudflare-security", name: "Cloudflare for Families", detail: String(localized: "Also blocks known malware."), url: "https://security.cloudflare-dns.com/dns-query", servers: ["1.1.1.2", "1.0.0.2"]),
            Provider(id: "quad9", name: "Quad9", detail: String(localized: "Non-profit; blocks known malicious domains."), url: "https://dns.quad9.net/dns-query", servers: ["9.9.9.9", "149.112.112.112"]),
            Provider(id: "mullvad", name: "Mullvad", detail: String(localized: "No logging."), url: "https://dns.mullvad.net/dns-query", servers: ["194.242.2.2"]),
            Provider(id: "adguard", name: "AdGuard", detail: String(localized: "Blocks ads and trackers."), url: "https://dns.adguard-dns.com/dns-query", servers: ["94.140.14.14", "94.140.15.15"]),
            Provider(id: "google", name: "Google Public DNS", detail: String(localized: "Reliable and widely used."), url: "https://dns.google/dns-query", servers: ["8.8.8.8", "8.8.4.4"]),
        ]
    }

    private(set) var isConfigured = false
    private(set) var isEnabled = false
    private(set) var currentURL: String?
    var lastError: String?
    @ObservationIgnored private let logger = Logger(subsystem: XPCConstants.logSubsystem, category: "dns")

    func refresh() async {
        let manager = NEDNSSettingsManager.shared()
        do {
            try await manager.loadFromPreferences()
            isConfigured = manager.dnsSettings != nil
            isEnabled = manager.isEnabled
            currentURL = (manager.dnsSettings as? NEDNSOverHTTPSSettings)?.serverURL?.absoluteString
        } catch {
            lastError = error.localizedDescription
        }
    }

    func configure(url: String, servers: [String]) async {
        guard let serverURL = URL(string: url), serverURL.scheme == "https" else {
            lastError = String(localized: "The server address must start with https://")
            return
        }
        let manager = NEDNSSettingsManager.shared()
        do {
            try await manager.loadFromPreferences()
            let settings = NEDNSOverHTTPSSettings(servers: servers)
            settings.serverURL = serverURL
            manager.dnsSettings = settings
            manager.localizedDescription = "Squealer Encrypted DNS"
            try await manager.saveToPreferences()
            lastError = nil
        } catch {
            logger.error("Couldn't save DNS settings: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
        await refresh()
    }

    func remove() async {
        let manager = NEDNSSettingsManager.shared()
        do {
            try await manager.loadFromPreferences()
            try await manager.removeFromPreferences()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
    }
}
