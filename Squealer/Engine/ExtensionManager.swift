import Foundation
import NetworkExtension
import Observation
import os
import SquealerKit
import SystemExtensions

/// Installs the system extension and turns the content filter on and off.
@MainActor @Observable
final class ExtensionManager: NSObject {
    enum Status: Equatable {
        case checking
        case notInstalled
        case awaitingApproval
        case activating
        case needsReboot
        case filterDisabled
        case running
        case failed(String)

        var isRunning: Bool { self == .running }
    }

    private(set) var status: Status = .checking
    private(set) var installedVersion: String?
    @ObservationIgnored private var pendingDeactivation = false
    @ObservationIgnored private var attemptedReplacement = false
    @ObservationIgnored private let logger = Logger(subsystem: XPCConstants.logSubsystem, category: "extension")

    @ObservationIgnored private let isDemo: Bool

    init(demo: Bool = false) {
        isDemo = demo
        super.init()
        if demo {
            status = .running
            return
        }
        NotificationCenter.default.addObserver(forName: .NEFilterConfigurationDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    /// Queries the installed extension and the filter configuration without changing anything.
    func refresh() async {
        guard !isDemo else { return }
        submit(.propertiesRequest(forExtensionWithIdentifier: XPCConstants.extensionBundleID, queue: .main))
    }

    func activate() {
        status = .activating
        submit(.activationRequest(forExtensionWithIdentifier: XPCConstants.extensionBundleID, queue: .main))
    }

    func deactivate() async {
        await setFilterEnabled(false)
        pendingDeactivation = true
        submit(.deactivationRequest(forExtensionWithIdentifier: XPCConstants.extensionBundleID, queue: .main))
    }

    func setFilterEnabled(_ enabled: Bool) async {
        let manager = NEFilterManager.shared()
        do {
            try await manager.loadFromPreferences()
            if manager.providerConfiguration == nil || enabled {
                let configuration = NEFilterProviderConfiguration()
                configuration.filterSockets = true
                configuration.filterPackets = false
                configuration.filterDataProviderBundleIdentifier = XPCConstants.extensionBundleID
                manager.providerConfiguration = configuration
                manager.localizedDescription = "Squealer"
            }
            manager.isEnabled = enabled
            try await manager.saveToPreferences()
            status = enabled ? .running : .filterDisabled
        } catch {
            logger.error("Filter configuration failed: \(error.localizedDescription, privacy: .public)")
            status = enabled ? .filterDisabled : status
        }
    }

    /// Turning the filter off and on makes macOS restart the extension, which re-registers its XPC service.
    func restartFilter() async {
        await setFilterEnabled(false)
        try? await Task.sleep(for: .seconds(1))
        await setFilterEnabled(true)
    }

    private func filterIsEnabled() async -> Bool {
        let manager = NEFilterManager.shared()
        guard (try? await manager.loadFromPreferences()) != nil else { return false }
        return manager.isEnabled && manager.providerConfiguration?.filterDataProviderBundleIdentifier == XPCConstants.extensionBundleID
    }

    private static var bundledExtensionBuild: String? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions/\(XPCConstants.extensionBundleID).systemextension")
        return Bundle(url: url)?.infoDictionary?["CFBundleVersion"] as? String
    }

    private func submit(_ request: OSSystemExtensionRequest) {
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func didActivate() async {
        if await filterIsEnabled() {
            status = .running
        } else {
            await setFilterEnabled(true)
        }
    }
}

extension ExtensionManager: OSSystemExtensionRequestDelegate {
    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension replacement: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in self.status = .awaitingApproval }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            if self.pendingDeactivation {
                self.pendingDeactivation = false
                self.status = .notInstalled
                return
            }
            switch result {
            case .completed: await self.didActivate()
            case .willCompleteAfterReboot: self.status = .needsReboot
            @unknown default: self.status = .failed("Unexpected result")
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) {
        let message = error.localizedDescription
        let code = (error as NSError).code
        Task { @MainActor in
            self.logger.error("Extension request failed: \(message, privacy: .public)")
            self.pendingDeactivation = false
            if code == OSSystemExtensionError.Code.requestCanceled.rawValue {
                return
            }
            self.status = .failed(message)
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        let active = properties.first { $0.isEnabled && !$0.isUninstalling }
        let isActive = active != nil
        let awaiting = properties.contains { $0.isAwaitingUserApproval }
        let version = active.map { "\($0.bundleShortVersion) (\($0.bundleVersion))" }
        let installedBuild = active?.bundleVersion
        Task { @MainActor in
            self.installedVersion = version
            if isActive, !self.attemptedReplacement, let installedBuild, let bundled = Self.bundledExtensionBuild, installedBuild != bundled {
                self.attemptedReplacement = true
                // The app was updated: replace the running extension with the one it ships.
                self.logger.info("Replacing extension \(installedBuild, privacy: .public) with \(bundled, privacy: .public)")
                self.activate()
                return
            }
            if isActive {
                self.status = await self.filterIsEnabled() ? .running : .filterDisabled
            } else if awaiting {
                self.status = .awaitingApproval
            } else {
                self.status = .notInstalled
            }
        }
    }
}
