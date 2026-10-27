import CoreLocation
import CoreWLAN
import Network
import os
import SquealerKit

/// Activates the profile whose network condition matches the current network. Reading the Wi-Fi name needs
/// Location Services permission, which is only requested once a profile actually uses a Wi-Fi condition.
@MainActor
final class ProfileAutoSwitcher: NSObject, CLLocationManagerDelegate {
    private let model: AppModel
    private let monitor = NWPathMonitor()
    private let locationManager = CLLocationManager()
    private var lastPath: NWPath?
    private let logger = Logger(subsystem: XPCConstants.logSubsystem, category: "profiles")

    init(model: AppModel) {
        self.model = model
        super.init()
        locationManager.delegate = self
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.lastPath = path
                self?.evaluate()
            }
        }
        monitor.start(queue: .main)
    }

    var currentSSID: String? {
        CWWiFiClient.shared().interface()?.ssid()
    }

    func requestLocationIfNeeded() {
        let usesWiFi = model.profiles.contains { if case .wifi = $0.autoSwitch { return true } else { return false } }
        if usesWiFi, locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    /// Called with the Wi-Fi name the first time this Mac joins a network no profile is set up for.
    var onNewNetwork: ((String) -> Void)?

    static var asksOnNewNetworks: Bool {
        UserDefaults.standard.object(forKey: "profiles.askOnNewNetwork") as? Bool ?? true
    }

    func evaluate() {
        guard model.connection.isConnected, let path = lastPath, path.status == .satisfied else { return }
        let candidates = model.profiles.filter { $0.autoSwitch != nil }
        let wantsPrompt = Self.asksOnNewNetworks && !model.profiles.isEmpty
        guard !candidates.isEmpty || wantsPrompt else { return }
        if wantsPrompt, locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
        requestLocationIfNeeded()

        let ssid = currentSSID
        let match = candidates.first { profile in
            switch profile.autoSwitch {
            case .wifi(let ssids): ssid.map(ssids.contains) ?? false
            case .interfaceType(let kind): path.usesInterfaceType(kind.networkType) || (kind == .vpn && path.availableInterfaces.contains { $0.type == .other })
            case nil: false
            }
        }

        if wantsPrompt, match == nil, let ssid, path.usesInterfaceType(.wifi) {
            let stored = UserDefaults.standard.stringArray(forKey: "profiles.knownNetworks")
            var known = Set(stored ?? [])
            // The network Squealer first sees isn't "new"; only ask about ones joined later.
            if known.insert(ssid).inserted, stored != nil {
                onNewNetwork?(ssid)
            }
            UserDefaults.standard.set(Array(known), forKey: "profiles.knownNetworks")
        }

        let active = model.activeProfile
        if let match, match.id != active?.id {
            logger.info("Switching to profile \(match.name, privacy: .public)")
            model.activateProfile(match.id)
        } else if match == nil, active?.autoSwitch != nil {
            model.activateProfile(nil)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.evaluate() }
    }
}

private extension InterfaceKind {
    var networkType: NWInterface.InterfaceType {
        switch self {
        case .wifi: .wifi
        case .wired: .wiredEthernet
        case .cellular: .cellular
        case .vpn: .other
        }
    }
}
