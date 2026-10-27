import AppKit
import SquealerKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    let extensionManager: ExtensionManager
    private var alertPanel: AlertPanelController?
    private var profileSwitcher: ProfileAutoSwitcher?
    private var networkPrompt: NetworkPromptController?
    private var housekeeping: Task<Void, Never>?

    static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    static let isDemo = isTesting || CommandLine.arguments.contains("-demo") || ProcessInfo.processInfo.environment["SQUEALER_DEMO"] == "1"

    override init() {
        let demo = Self.isDemo
        model = AppModel(backend: demo ? DemoBackend() : EngineClient(), isDemo: demo)
        extensionManager = ExtensionManager(demo: demo)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isTesting else { return }
        _ = Updater.shared
        Diagnostics.shared.start()
        alertPanel = AlertPanelController(model: model)
        profileSwitcher = ProfileAutoSwitcher(model: model)
        let networkPrompt = NetworkPromptController(model: model)
        self.networkPrompt = networkPrompt
        profileSwitcher?.onNewNetwork = { ssid in networkPrompt.show(ssid: ssid) }
        model.start()
        observeWindows()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.model.endLoginSession() }
        }
        #if DEBUG
        WindowSnapshots.scheduleIfRequested()
        WindowSnapshots.scheduleDumpIfRequested(model: model)
        WindowSnapshots.scheduleTourIfRequested(model: model, extensionManager: extensionManager)
        #endif

        housekeeping = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                self?.housekeep()
            }
        }
    }

    private func housekeep() {
        if extensionManager.status.isRunning, model.connection == .disconnected {
            model.connect()
        }
        profileSwitcher?.evaluate()

        let defaults = UserDefaults.standard
        let learningUntil = defaults.double(forKey: "learning.until")
        if learningUntil > 0, Date.now.timeIntervalSince1970 > learningUntil, model.connection.isConnected {
            defaults.set(0, forKey: "learning.until")
            if model.settings.mode == .silentAllow {
                model.setMode(.alert)
                notifyLearningFinished()
            }
        }
    }

    private func notifyLearningFinished() {
        let count = model.review.count
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Squealer finished learning")
            content.body = String(localized: "\(count) connections are ready to review. From now on, new connections ask first.")
            try? await center.add(UNNotificationRequest(identifier: "learning-finished", content: content, trigger: nil))
        }
    }

    /// Squealer is a menu bar app, but shows in the Dock and app switcher while one of its windows is open.
    private func observeWindows() {
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100))
                    self?.updateActivationPolicy()
                }
            }
        }
    }

    private func updateActivationPolicy() {
        let hasWindow = NSApp.windows.contains { window in
            window.isVisible && !(window is NSPanel) && window.styleMask.contains(.titled) && window.level == .normal
        }
        let policy: NSApplication.ActivationPolicy = hasWindow ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
