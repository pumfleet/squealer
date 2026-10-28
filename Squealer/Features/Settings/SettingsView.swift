import UniformTypeIdentifiers
import ServiceManagement
import SquealerKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Alerts", systemImage: "bell.badge") { AlertSettings() }
            Tab("Defaults", systemImage: "checkmark.shield") { DefaultsSettings() }
            Tab("DNS", systemImage: "lock.icloud") { EncryptedDNSSettings() }
            Tab("Data", systemImage: "internaldrive") { DataSettings() }
            Tab("Advanced", systemImage: "wrench.and.screwdriver") { AdvancedSettings() }
        }
        .frame(width: 560)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("menubar.showRates") private var showRates = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Picker("When no rule matches", selection: Binding(get: { model.settings.mode }, set: { model.setMode($0) })) {
                    ForEach(FilterMode.allCases, id: \.self) { mode in
                        Text(Theme.summary(for: mode)).tag(mode)
                    }
                }
                Picker("Profile", selection: Binding(get: { model.settings.activeProfileID }, set: { model.activateProfile($0) })) {
                    Text("Default").tag(UUID?.none)
                    ForEach(model.profiles) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            Section {
                Toggle("Open Squealer at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Toggle("Show network speed in the menu bar", isOn: $showRates)
                Toggle(isOn: Binding(get: { model.settings.requireAuthentication }, set: { value in model.update { $0.requireAuthentication = value } })) {
                    Text("Require Touch ID or password for changes")
                    Text("Protects rules and settings from anyone else using this Mac. Answering alerts never asks.")
                }
            } footer: {
                Text("Filtering keeps working when Squealer isn't open; you just won't be asked about new connections.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AlertSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("alert.remote") private var remoteScope: AlertScope.Remote = .domain
    @AppStorage("alert.ports") private var portScope: AlertScope.Ports = .any
    @AppStorage("alert.duration") private var duration: AlertScope.Duration = .forever
    @AppStorage("alert.sound") private var playSound = true

    var body: some View {
        Form {
            Section("Default choices in alerts") {
                Picker("Server", selection: $remoteScope) {
                    Text("The exact host").tag(AlertScope.Remote.host)
                    Text("The whole domain").tag(AlertScope.Remote.domain)
                    Text("Any server").tag(AlertScope.Remote.any)
                }
                Picker("Port", selection: $portScope) {
                    Text("Only that port").tag(AlertScope.Ports.this)
                    Text("Any port").tag(AlertScope.Ports.any)
                }
                Picker("Duration", selection: $duration) {
                    Text("Once").tag(AlertScope.Duration.once)
                    Text("For a minute").tag(AlertScope.Duration.minute)
                    Text("Until the app quits").tag(AlertScope.Duration.untilQuit)
                    Text("For an hour").tag(AlertScope.Duration.hour)
                    Text("Until the Mac restarts").tag(AlertScope.Duration.untilRestart)
                    Text("Until you log out").tag(AlertScope.Duration.untilLogout)
                    Text("Forever").tag(AlertScope.Duration.forever)
                }
            }
            Section {
                Toggle("Play a sound for new alerts", isOn: $playSound)
                Picker("If an alert isn't answered", selection: Binding(get: { model.settings.alertTimeout }, set: { value in model.update { $0.alertTimeout = value } })) {
                    Text("Keep waiting").tag(TimeInterval(0))
                    Text("After 1 minute").tag(TimeInterval(60))
                    Text("After 5 minutes").tag(TimeInterval(300))
                    Text("After 15 minutes").tag(TimeInterval(900))
                }
                if model.settings.alertTimeout > 0 {
                    Picker("Then", selection: Binding(get: { model.settings.alertTimeoutAction }, set: { value in model.update { $0.alertTimeoutAction = value } })) {
                        Text("Allow the connection").tag(UnansweredAlertAction.allow)
                        Text("Deny the connection").tag(UnansweredAlertAction.deny)
                    }
                }
                Picker("When Squealer isn't running", selection: Binding(get: { model.settings.noClientAction }, set: { value in model.update { $0.noClientAction = value } })) {
                    Text("Allow new connections").tag(UnansweredAlertAction.allow)
                    Text("Deny new connections").tag(UnansweredAlertAction.deny)
                }
            } footer: {
                Text("Connections decided without you are collected in Review so you can make rules for them later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DefaultsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var trusting = false
    @State private var trustResult: String?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: setting(\.allowApplePlatformBinaries)) {
                    Text("Allow Apple system software")
                    Text("macOS services and Apple's built-in apps connect without asking.")
                }
                Toggle(isOn: setting(\.allowAppStoreApps)) {
                    Text("Allow apps from the App Store")
                    Text("Apps Apple has reviewed and signed for the Mac App Store connect without asking.")
                }
                Toggle(isOn: setting(\.allowSystemNetworkServices)) {
                    Text("Allow essential network services")
                    Text("DNS, DHCP and time synchronisation. Turning this off can break your connection.")
                }
                Toggle(isOn: setting(\.allowAppleServices)) {
                    Text("Allow any app to reach Apple and iCloud")
                    Text("Push notifications, iCloud sync, Sign in with Apple and purchases go through Apple's servers.")
                }
                Toggle(isOn: setting(\.allowLocalNetworkDiscovery)) {
                    Text("Allow local network discovery")
                    Text("Bonjour, AirPlay, casting and printer discovery on your local network.")
                }
                Toggle(isOn: setting(\.allowApprovedSystemExtensions)) {
                    Text("Allow approved system extensions")
                    Text("VPNs and security tools you've already approved in System Settings.")
                }
            } header: {
                Text("Connections allowed without a rule")
            } footer: {
                Text("Your rules always take precedence over these defaults.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent {
                    if trusting {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Trust Installed Apps") { trustInstalledApps() }
                    }
                } label: {
                    Text("Apps already in your Applications folder")
                    Text(trustResult ?? String(localized: "Creates an allow rule for each one, so only apps you install from now on ask first."))
                }
            }
            Section {
                Toggle(isOn: setting(\.filterInbound)) {
                    Text("Filter incoming connections")
                    Text("Ask before other devices connect to apps on this Mac, for example file sharing or a development server.")
                }
                if model.settings.filterInbound {
                    Toggle(isOn: setting(\.allowIncomingFromLocalNetwork)) {
                        Text("Allow incoming connections from the local network")
                        Text("Only ask about connections from the internet. Unrequested incoming UDP traffic is blocked without asking.")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func trustInstalledApps() {
        trusting = true
        Task {
            let existing = Set(model.rules.map(\.process))
            let rules = await InstalledApps.trustRules().filter { !existing.contains($0.process) }
            model.save(rules)
            trustResult = rules.isEmpty
                ? String(localized: "All installed apps already have rules.")
                : String(localized: "Added \(rules.count) rules. You can review them under Rules.")
            trusting = false
        }
    }

    private func setting(_ keyPath: WritableKeyPath<EngineSettings, Bool>) -> Binding<Bool> {
        Binding(get: { model.settings[keyPath: keyPath] }, set: { value in model.update { $0[keyPath: keyPath] = value } })
    }
}

private struct DataSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmClear = false
    @State private var backups: [BackupInfo] = []
    @State private var restoring: BackupInfo?
    @State private var exportDocument: BackupDocument?
    @State private var importing = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Picker("Keep traffic history for", selection: Binding(get: { model.settings.historyRetentionDays }, set: { value in model.update { $0.historyRetentionDays = value } })) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("1 year").tag(365)
                }
                Button("Clear Traffic History…", role: .destructive) { confirmClear = true }
            } footer: {
                Text("History and the connection log never leave this Mac. They record which app connected where and how much data moved, never the content of your traffic.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(backups.prefix(8)) { backup in
                    HStack {
                        Image(systemName: backup.isAutomatic ? "clock.arrow.circlepath" : "externaldrive.badge.checkmark")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(backup.created.formatted(date: .abbreviated, time: .shortened))
                            Text("\(backup.isAutomatic ? String(localized: "Automatic") : String(localized: "Manual")) · ^[\(backup.rules) rule](inflect: true)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore…") { restoring = backup }
                            .controlSize(.small)
                    }
                }
                HStack {
                    Button("Back Up Now") { Task { backups = await model.createBackup() } }
                    Spacer()
                    Button("Export…") {
                        Task { if let backup = await model.exportConfiguration() { exportDocument = BackupDocument(backup: backup) } }
                    }
                    Button("Import…") { importing = true }
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Backups")
            } footer: {
                Text("Squealer backs up your rules, groups, profiles, blocklists and settings once a day and keeps the last two weeks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { backups = await model.backups() }
        .confirmationDialog(
            "Restore the backup from \(restoring?.created.formatted(date: .abbreviated, time: .shortened) ?? "")?",
            isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }),
            presenting: restoring
        ) { backup in
            Button("Restore") {
                Task {
                    message = await model.restoreBackup(backup.id)
                        ? String(localized: "Restored. Your previous configuration was backed up first.")
                        : String(localized: "The backup couldn't be restored.")
                    backups = await model.backups()
                }
            }
        } message: { _ in
            Text("Your current rules and settings are replaced. They're backed up first, so you can undo this.")
        }
        .fileExporter(
            isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
            document: exportDocument,
            contentType: .json,
            defaultFilename: "Squealer Backup"
        ) { _ in }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard let url = try? result.get() else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), let backup = BackupDocument.decode(data) else {
                message = String(localized: "That file isn't a Squealer backup.")
                return
            }
            Task {
                message = await model.restore(backup)
                    ? String(localized: "Imported. Your previous configuration was backed up first.")
                    : String(localized: "The backup couldn't be imported.")
                backups = await model.backups()
            }
        }
        .confirmationDialog("Clear all traffic history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { model.clearHistory() }
        } message: {
            Text("Your rules are kept.")
        }
    }
}

private struct AdvancedSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(ExtensionManager.self) private var extensionManager
    @State private var downloadingCity = false
    @State private var cityError: String?
    @State private var hasCity = GeoService.shared.hasCityDatabase
    @State private var confirmUninstall = false
    @State private var cliMessage: String?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { model.settings.observeDNS }, set: { value in model.update { $0.observeDNS = value } })) {
                    Text("Learn host names from DNS")
                    Text("Watches DNS answers on this Mac so connections show names instead of bare addresses.")
                }
            }
            Section {
                LabeledContent("Location data") {
                    if downloadingCity {
                        ProgressView().controlSize(.small)
                    } else if hasCity {
                        Button("Remove City Data") {
                            GeoService.shared.removeCityDatabase()
                            hasCity = false
                        }
                    } else {
                        Button("Download City Data (130 MB)") { downloadCity() }
                    }
                }
                if let cityError {
                    Text(cityError).font(.caption).foregroundStyle(Theme.deny)
                }
            } footer: {
                Text("Country and network owner data is built in. City-level data makes the map more precise. IP geolocation by DB-IP.com.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Command-line tool") {
                    Button(CommandLineTool.isInstalled ? "Reinstall" : "Install…") { cliMessage = CommandLineTool.install() }
                }
                if let cliMessage {
                    Text(cliMessage).font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Diagnostics") {
                    HStack {
                        Button("Show in Finder") { Diagnostics.reveal() }
                        Link("Report an Issue…", destination: Links.newIssue)
                    }
                }
            } footer: {
                Text("Installs `squealer` in /usr/local/bin, for scripting and checking status from Terminal. Changing settings from the command line requires sudo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Network extension") {
                LabeledContent("Status", value: statusText)
                if let version = extensionManager.installedVersion {
                    LabeledContent("Version", value: version)
                }
                if case .connected(let version) = model.connection {
                    LabeledContent("Engine", value: version)
                }
                HStack {
                    Button("Restart") { Task { await extensionManager.restartFilter() } }
                        .help("Turns the filter off and on again, which restarts the extension")
                    Button("Reinstall") { extensionManager.activate() }
                    Button("Uninstall Squealer…", role: .destructive) { confirmUninstall = true }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Uninstall Squealer?", isPresented: $confirmUninstall) {
            Button("Uninstall and Keep Rules", role: .destructive) {
                Task { await uninstall(erasingData: false) }
            }
            Button("Uninstall and Delete All Data", role: .destructive) {
                Task { await uninstall(erasingData: true) }
            }
        } message: {
            Text("Filtering stops immediately. Kept rules come back if you reinstall. You can then move Squealer to the Trash.")
        }
    }

    private func uninstall(erasingData: Bool) async {
        if erasingData {
            guard await model.eraseAllData() else { return }
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try? FileManager.default.removeItem(at: support.appendingPathComponent("Squealer", isDirectory: true))
            if let bundleID = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: bundleID)
            }
        }
        await extensionManager.deactivate()
        CommandLineTool.uninstall()
        try? await SMAppService.mainApp.unregister()
    }

    private var statusText: String {
        switch extensionManager.status {
        case .running: String(localized: "Running")
        case .checking: String(localized: "Checking…")
        case .notInstalled: String(localized: "Not installed")
        case .awaitingApproval: String(localized: "Waiting for approval")
        case .activating: String(localized: "Installing…")
        case .needsReboot: String(localized: "Restart required")
        case .filterDisabled: String(localized: "Filter turned off")
        case .failed(let message): message
        }
    }

    private func downloadCity() {
        downloadingCity = true
        cityError = nil
        Task {
            do {
                try await GeoService.shared.downloadCityDatabase()
                hasCity = true
            } catch {
                cityError = error.localizedDescription
            }
            downloadingCity = false
        }
    }
}

private struct EncryptedDNSSettings: View {
    @State private var dns = EncryptedDNS()
    @State private var providerID = EncryptedDNS.Provider.all[0].id
    @State private var customURL = ""
    @State private var working = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    if !dns.isConfigured {
                        Text("Off")
                    } else if dns.isEnabled {
                        Label("On", systemImage: "lock.fill").foregroundStyle(Theme.allow)
                    } else {
                        Text("Set up, but turned off in System Settings").foregroundStyle(Theme.pending)
                    }
                }
                if let url = dns.currentURL {
                    LabeledContent("Server", value: url)
                }
            } footer: {
                Text("Encrypts the DNS lookups your Mac makes, so your network and internet provider can't see or change which sites you look up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Provider") {
                Picker("Provider", selection: $providerID) {
                    ForEach(EncryptedDNS.Provider.all) { provider in
                        VStack(alignment: .leading) {
                            Text(provider.name)
                            Text(provider.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(provider.id)
                    }
                    Text("Custom").tag("custom")
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                if providerID == "custom" {
                    TextField("DNS-over-HTTPS URL", text: $customURL, prompt: Text("https://dns.example.com/dns-query"))
                }
                HStack {
                    Button(dns.isConfigured ? "Update" : "Turn On…") { apply() }
                        .buttonStyle(.borderedProminent)
                        .disabled(working || (providerID == "custom" && customURL.isEmpty))
                    if dns.isConfigured {
                        Button("Turn Off") { Task { working = true; await dns.remove(); working = false } }
                    }
                    if dns.isConfigured && !dns.isEnabled {
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")!)
                        }
                    }
                    if working { ProgressView().controlSize(.small) }
                }
                if let error = dns.lastError {
                    Text(error).font(.caption).foregroundStyle(Theme.deny)
                }
            }
            Section {
                Text("With encrypted DNS on, Squealer can no longer read DNS answers to name connections made by address. Most apps tell Squealer the host name directly, so you'll rarely notice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await dns.refresh() }
    }

    private func apply() {
        working = true
        Task {
            if providerID == "custom" {
                await dns.configure(url: customURL, servers: [])
            } else if let provider = EncryptedDNS.Provider.all.first(where: { $0.id == providerID }) {
                await dns.configure(url: provider.url, servers: provider.servers)
            }
            working = false
        }
    }
}

struct BackupDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var backup: ConfigurationBackup

    init(backup: ConfigurationBackup) {
        self.backup = backup
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let backup = Self.decode(data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.backup = backup
    }

    static func decode(_ data: Data) -> ConfigurationBackup? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let backup = try? decoder.decode(ConfigurationBackup.self, from: data), backup.format == "squealer-backup" else { return nil }
        return backup
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return FileWrapper(regularFileWithContents: try encoder.encode(backup))
    }
}
