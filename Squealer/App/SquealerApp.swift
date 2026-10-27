import SwiftUI

@main
struct SquealerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appDelegate.model)
                .environment(appDelegate.extensionManager)
        } label: {
            MenuBarLabel()
                .environment(appDelegate.model)
                .environment(appDelegate.extensionManager)
                .modifier(LaunchCoordinator(extensionManager: appDelegate.extensionManager))
        }
        .menuBarExtraStyle(.window)

        Window("Squealer", id: "main") {
            MainWindow()
                .environment(appDelegate.model)
                .environment(appDelegate.extensionManager)
        }
        .defaultSize(width: 1180, height: 720)
        .commands {
            SidebarCommands()
            InspectorCommands()
        }

        Window("Welcome to Squealer", id: "onboarding") {
            OnboardingView()
                .environment(appDelegate.model)
                .environment(appDelegate.extensionManager)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)

        Settings {
            SettingsView()
                .environment(appDelegate.model)
                .environment(appDelegate.extensionManager)
        }
    }
}

/// Opens onboarding on first launch, or whenever the extension isn't set up.
private struct LaunchCoordinator: ViewModifier {
    var extensionManager: ExtensionManager
    @Environment(\.openWindow) private var openWindow
    @AppStorage("onboarding.completed") private var completed = false

    func body(content: Content) -> some View {
        content.task {
            guard !AppDelegate.isTesting else { return }
            #if DEBUG
            if let index = CommandLine.arguments.firstIndex(of: "-open"), CommandLine.arguments.indices.contains(index + 1) {
                openWindow(id: CommandLine.arguments[index + 1])
                return
            }
            #endif
            if AppDelegate.isDemo {
                openWindow(id: "main")
                return
            }
            await extensionManager.refresh()
            try? await Task.sleep(for: .milliseconds(400))
            #if DEBUG
            if CommandLine.arguments.contains("-activate") {
                extensionManager.activate()
            }
            if CommandLine.arguments.contains("-restart-filter") {
                await extensionManager.restartFilter()
            }
            #endif
            if !completed || extensionManager.status == .notInstalled {
                openWindow(id: "onboarding")
                NSApp.activate()
            }
        }
    }
}
