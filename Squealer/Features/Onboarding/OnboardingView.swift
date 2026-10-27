import SquealerKit
import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(ExtensionManager.self) private var extensionManager
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("onboarding.completed") private var completed = false
    @AppStorage("learning.until") private var learningUntil: Double = 0
    @State private var step = Step.welcome
    @State private var posture = Posture.learn
    @State private var trustInstalledApps = true

    enum Step: Int, CaseIterable {
        case welcome, install, posture, done
    }

    enum Posture: String, CaseIterable, Identifiable {
        case balanced, strict, learn
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .install: install
                case .posture: postureStep
                case .done: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))

            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(Step.allCases, id: \.self) { item in
                        Capsule()
                            .fill(item == step ? Theme.brand : Color.secondary.opacity(0.3))
                            .frame(width: item == step ? 18 : 6, height: 6)
                    }
                }
                .animation(.snappy, value: step)
                Spacer()
                if step != .welcome && step != .done {
                    Button("Back") { go(-1) }
                }
                Button(primaryTitle) { primaryAction() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(step == .install && !extensionManager.status.isRunning)
            }
            .padding(16)
        }
        .frame(width: 620, height: 500)
        .background(.background)
        .task { await extensionManager.refresh() }
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Welcome to Squealer")
                .font(.largeTitle.weight(.bold))
            Text("See every app that talks to the internet, and decide which ones may.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 14) {
                Feature(symbol: "bell.badge.fill", title: "Ask before connecting", detail: "A quiet alert appears when an app reaches a new server. Allow it once, for an hour, or forever.")
                Feature(symbol: "waveform.path.ecg", title: "Watch traffic live", detail: "Per-app speeds, totals, history and a world map of where your data goes.")
                Feature(symbol: "shield.checkered", title: "Block trackers everywhere", detail: "Subscribe to curated blocklists and switch rule profiles automatically by network.")
            }
            .frame(maxWidth: 440)
            .padding(.top, 8)
        }
    }

    private var install: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Turn on the network filter")
                .font(.title.weight(.bold))
            Text("Squealer filters connections with a network extension built into macOS. It never sees the content of your traffic, only which app connects where.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                InstallStep(number: 1, title: "Install the extension", state: installState) {
                    Button("Install") { extensionManager.activate() }
                        .disabled(extensionManager.status == .activating)
                }
                InstallStep(number: 2, title: "Allow it in System Settings", state: approvalState) {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                    }
                }
                if extensionManager.status == .awaitingApproval {
                    Text("Under Network Extensions, turn on Squealer. If macOS asks whether Squealer may filter network content, choose Allow.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 34)
                }
                InstallStep(number: 3, title: "Start filtering", state: extensionManager.status.isRunning ? .done : .waiting) {
                    if extensionManager.status == .filterDisabled {
                        Button("Turn On") { Task { await extensionManager.setFilterEnabled(true) } }
                    }
                }
            }
            .card()

            if case .failed(let message) = extensionManager.status {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.deny)
                    .font(.callout)
            }
            if extensionManager.status == .needsReboot {
                Label("Restart your Mac to finish installing.", systemImage: "arrow.clockwise.circle.fill")
                    .foregroundStyle(Theme.pending)
            }
            Spacer()
        }
        .task(id: extensionManager.status) {
            guard extensionManager.status == .awaitingApproval else { return }
            while !Task.isCancelled, extensionManager.status == .awaitingApproval {
                try? await Task.sleep(for: .seconds(2))
                await extensionManager.refresh()
            }
        }
    }

    private var installState: InstallStepState {
        switch extensionManager.status {
        case .notInstalled, .checking: .waiting
        case .activating: .working
        case .failed: .failed
        default: .done
        }
    }

    private var approvalState: InstallStepState {
        switch extensionManager.status {
        case .awaitingApproval: .working
        case .running, .filterDisabled, .needsReboot: .done
        default: .waiting
        }
    }

    private var postureStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How careful should Squealer be?")
                .font(.title.weight(.bold))
            Text("You can change this at any time from the menu bar.")
                .foregroundStyle(.secondary)
            VStack(spacing: 10) {
                PostureOption(posture: .learn, selection: $posture, symbol: "graduationcap.fill", title: "Learn first (recommended)", detail: "Allow everything silently for three days and record it. Then review what happened and turn it into rules, and Squealer starts asking.")
                PostureOption(posture: .balanced, selection: $posture, symbol: "scalemass.fill", title: "Ask now", detail: "Apple software and App Store apps connect freely. You're asked about everything else from the start.")
                PostureOption(posture: .strict, selection: $posture, symbol: "lock.shield.fill", title: "Strict", detail: "Only essential macOS services connect freely. You're asked about every app, including Apple's.")
            }
            Toggle(isOn: $trustInstalledApps) {
                Text("Trust apps that are already installed")
                Text("Apps in your Applications folder keep connecting without asking. New apps you install later will ask.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(posture == .strict)
            .padding(.top, 4)
            Spacer()
        }
    }

    private var done: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 64))
                .foregroundStyle(Theme.allow.gradient)
            Text("You're protected")
                .font(.largeTitle.weight(.bold))
            VStack(alignment: .leading, spacing: 12) {
                Feature(symbol: "menubar.arrow.up.rectangle", title: "Squealer lives in the menu bar", detail: "Switch modes and profiles, and see what's active right now.")
                Feature(symbol: "keyboard", title: "Answer alerts from the keyboard", detail: "Return allows, ⌘⌫ denies and Escape decides later.")
                Feature(symbol: "tray.full.fill", title: "Nothing is lost", detail: "Connections Squealer allowed without asking wait for you in Review, so you can make rules whenever you like.")
            }
            .frame(maxWidth: 440)
        }
    }

    private var primaryTitle: LocalizedStringKey {
        switch step {
        case .welcome: "Get Started"
        case .install: "Continue"
        case .posture: "Continue"
        case .done: "Done"
        }
    }

    private func primaryAction() {
        switch step {
        case .posture:
            applyPosture()
            go(1)
        case .done:
            completed = true
            dismissWindow(id: "onboarding")
        default:
            go(1)
        }
    }

    private func go(_ offset: Int) {
        withAnimation(.snappy) {
            step = Step(rawValue: step.rawValue + offset) ?? step
        }
    }

    private func applyPosture() {
        model.update { settings in
            switch posture {
            case .balanced:
                settings.mode = .alert
                settings.allowApplePlatformBinaries = true
                settings.allowAppStoreApps = true
            case .strict:
                settings.mode = .alert
                settings.allowApplePlatformBinaries = false
                settings.allowAppStoreApps = false
            case .learn:
                settings.mode = .silentAllow
                settings.allowApplePlatformBinaries = true
                settings.allowAppStoreApps = true
            }
        }
        learningUntil = posture == .learn ? Date.now.addingTimeInterval(3 * 86_400).timeIntervalSince1970 : 0
        if trustInstalledApps, posture != .strict {
            Task {
                let existing = Set(model.rules.map(\.process))
                model.save(await InstalledApps.trustRules().filter { !existing.contains($0.process) })
            }
        }
    }
}

private struct Feature: View {
    var symbol: String
    var title: LocalizedStringKey
    var detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Theme.brand)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

enum InstallStepState { case waiting, working, done, failed }

private struct InstallStep<Action: View>: View {
    var number: Int
    var title: LocalizedStringKey
    var state: InstallStepState
    @ViewBuilder var action: Action

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(background).frame(width: 24, height: 24)
                switch state {
                case .done: Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                case .working: ProgressView().controlSize(.mini)
                case .failed: Image(systemName: "exclamationmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                case .waiting: Text("\(number)").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                }
            }
            Text(title).fontWeight(.medium).foregroundStyle(state == .waiting ? .secondary : .primary)
            Spacer()
            if state != .done {
                action
            }
        }
    }

    private var background: Color {
        switch state {
        case .done: Theme.allow
        case .failed: Theme.deny
        case .working: Theme.brand.opacity(0.2)
        case .waiting: Color.secondary.opacity(0.15)
        }
    }
}

private struct PostureOption: View {
    var posture: OnboardingView.Posture
    @Binding var selection: OnboardingView.Posture
    var symbol: String
    var title: LocalizedStringKey
    var detail: LocalizedStringKey

    var body: some View {
        let selected = selection == posture
        Button {
            selection = posture
        } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(selected ? Color.white : Theme.brand)
                    .frame(width: 44, height: 44)
                    .background(selected ? AnyShapeStyle(Theme.brand.gradient) : AnyShapeStyle(Theme.brand.opacity(0.12)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Theme.brand : .secondary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Theme.brand.opacity(0.08) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? Theme.brand : Color.secondary.opacity(0.25), lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
