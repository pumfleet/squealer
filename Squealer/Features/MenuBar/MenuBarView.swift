import SquealerKit
import SwiftUI

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(ExtensionManager.self) private var extensionManager
    @AppStorage("menubar.showRates") private var showRates = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            if showRates, model.connection.isConnected {
                Text("\(Format.compactRate(model.currentRate.bytesIn))↓ \(Format.compactRate(model.currentRate.bytesOut))↑")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
            }
        }
    }

    private var symbol: String {
        guard extensionManager.status.isRunning else { return "shield.slash" }
        if !model.alerts.isEmpty { return "shield.lefthalf.filled.trianglebadge.exclamationmark" }
        return Theme.symbol(for: model.settings.mode)
    }
}

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(ExtensionManager.self) private var extensionManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if extensionManager.status.isRunning && model.connection.isConnected {
                ModeSwitcher()
                trafficCard
                ActiveAppsList()
                if !model.review.isEmpty {
                    reviewRow
                }
            } else {
                setupCard
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text("Squealer").font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !model.profiles.isEmpty {
                ProfileMenu()
            }
        }
    }

    private var statusText: LocalizedStringKey {
        switch extensionManager.status {
        case .running: model.connection.isConnected ? Theme.summary(for: model.settings.mode) : "Not connected to the network extension"
        case .checking: "Checking…"
        case .notInstalled: "Not set up yet"
        case .awaitingApproval: "Waiting for approval in System Settings"
        case .activating: "Installing the network extension…"
        case .needsReboot: "Restart your Mac to finish installing"
        case .filterDisabled: "The network filter is turned off"
        case .failed: "The network extension couldn't start"
        }
    }

    private var trafficCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Network activity").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                RateLegend(bytesIn: model.currentRate.bytesIn, bytesOut: model.currentRate.bytesOut)
            }
            TrafficSparkline(samples: model.rateHistory)
                .frame(height: 54)
        }
        .card()
    }

    private var reviewRow: some View {
        Button {
            openMain(.review)
        } label: {
            HStack {
                Image(systemName: "tray.full.fill")
                    .foregroundStyle(Theme.brand)
                Text("^[\(model.review.count) connection](inflect: true) to review")
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .card()
    }

    @ViewBuilder
    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if extensionManager.status.isRunning {
                Label("Can't reach the network extension.", systemImage: "bolt.horizontal.circle.fill")
                    .foregroundStyle(Theme.pending)
                    .font(.callout.weight(.medium))
                Text("Filtering continues with your rules, but Squealer can't ask about new connections or show live traffic until it reconnects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Try Again") {
                        model.connect()
                    }
                    if let since = model.disconnectedSince, Date.now.timeIntervalSince(since) > 20 {
                        Button("Restart Extension") {
                            Task { await extensionManager.restartFilter() }
                        }
                        .help("Turns the filter off and on, which restarts the network extension. If this doesn't help, restart your Mac.")
                    }
                }
            } else {
                Label("Squealer isn't protecting this Mac yet.", systemImage: "exclamationmark.shield.fill")
                    .foregroundStyle(Theme.pending)
                    .font(.callout.weight(.medium))
                Button("Finish Setup…") {
                    openWindow(id: "onboarding")
                    NSApp.activate()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var footer: some View {
        HStack(spacing: 18) {
            Button { openMain(.connections) } label: { Label("Monitor", systemImage: "waveform.path.ecg.rectangle") }
            Button { openMain(.rules) } label: { Label("Rules", systemImage: "list.bullet.rectangle") }
            Spacer()
            Button {
                openSettings()
                NSApp.activate()
            } label: { Image(systemName: "gearshape") }
                .accessibilityLabel("Settings")
                .help("Settings")
            Menu {
                Button("About Squealer") { AboutPanel.show() }
                if Updater.shared.isAvailable {
                    Button("Check for Updates…") {
                        Updater.shared.checkForUpdates()
                        NSApp.activate()
                    }
                }
                Link("Report an Issue…", destination: Links.newIssue)
                Divider()
                Button("Quit Squealer") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More")
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
    }

    private func openMain(_ section: MainSection) {
        NavigationModel.shared.section = section
        openWindow(id: "main")
        NSApp.activate()
    }
}

struct ModeSwitcher: View {
    @Environment(AppModel.self) private var model
    /// Icons only, for narrow places like the sidebar.
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 4 : 6) {
            ForEach(FilterMode.allCases, id: \.self) { mode in
                let selected = model.settings.mode == mode
                Button {
                    model.setMode(mode)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: Theme.symbol(for: mode))
                            .font(.system(size: compact ? 13 : 16, weight: .medium))
                            .frame(height: compact ? 16 : 20)
                        if !compact {
                            Text(Theme.title(for: mode))
                                .font(.caption.weight(.medium))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, compact ? 6 : 8)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(selected ? AnyShapeStyle(color(for: mode).gradient) : AnyShapeStyle(.quaternary.opacity(0.6)))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Theme.summary(for: mode))
                .accessibilityLabel(Theme.summary(for: mode))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .animation(.snappy(duration: 0.2), value: model.settings.mode)
    }

    private func color(for mode: FilterMode) -> Color {
        switch mode {
        case .alert: Theme.brand
        case .silentAllow: Theme.allow
        case .silentDeny: Theme.deny
        case .off: .gray
        }
    }
}

struct ProfileMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Picker("Profile", selection: Binding(get: { model.settings.activeProfileID }, set: { model.activateProfile($0) })) {
                Label("Default", systemImage: "circle.dashed").tag(UUID?.none)
                ForEach(model.profiles) { profile in
                    Label(profile.name, systemImage: profile.symbol).tag(Optional(profile.id))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(model.activeProfile?.name ?? String(localized: "Default"), systemImage: model.activeProfile?.symbol ?? "circle.dashed")
                .font(.caption.weight(.medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Active profile")
    }
}

struct ActiveAppsList: View {
    @Environment(AppModel.self) private var model

    private struct AppActivity: Identifiable {
        var process: ProcessIdentity
        var rateIn: Double
        var rateOut: Double
        var connections: Int
        var id: ProcessKey { process.key }
    }

    var body: some View {
        let apps = topApps
        VStack(alignment: .leading, spacing: 8) {
            Text("Most active").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if apps.isEmpty {
                Text("Nothing is using the network right now.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
            } else {
                let maximum = apps.map { $0.rateIn + $0.rateOut }.max() ?? 1
                ForEach(apps) { app in
                    HStack(spacing: 8) {
                        AppIcon(process: app.process, size: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(ProcessPresentation.name(for: app.process))
                                    .font(.callout)
                                    .lineLimit(1)
                                Spacer()
                                Text(Format.rate(app.rateIn + app.rateOut))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            RateBar(bytesIn: app.rateIn, bytesOut: app.rateOut, maximum: maximum)
                        }
                    }
                }
            }
        }
    }

    private var topApps: [AppActivity] {
        var byProcess: [ProcessKey: AppActivity] = [:]
        for summary in model.connections.values where summary.activeFlows > 0 || summary.rateIn + summary.rateOut > 0 {
            var activity = byProcess[summary.process.key] ?? AppActivity(process: summary.process, rateIn: 0, rateOut: 0, connections: 0)
            activity.rateIn += summary.rateIn
            activity.rateOut += summary.rateOut
            activity.connections += summary.activeFlows
            byProcess[summary.process.key] = activity
        }
        return byProcess.values
            .sorted { ($0.rateIn + $0.rateOut, $0.connections) > ($1.rateIn + $1.rateOut, $1.connections) }
            .prefix(5)
            .map { $0 }
    }
}
