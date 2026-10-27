import SquealerKit
import SwiftUI
import UniformTypeIdentifiers

struct RuleEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var onSave: (Rule) -> Void

    @State private var rule: Rule
    @State private var remoteKind: RemoteKind
    @State private var remoteText: String
    @State private var portsText: String
    @State private var lifetimeKind: LifetimeKind
    @State private var expiry: Date
    @State private var choosingApp = false
    private let isNew: Bool

    enum LifetimeKind: Hashable {
        case forever, until, untilRestart, untilLogout, untilQuit
    }

    private var isSubscribed: Bool { rule.origin == .subscription }

    enum RemoteKind: String, CaseIterable, Identifiable {
        case any, host, domain, address, localNetwork
        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .any: "Any server"
            case .host: "Host"
            case .domain: "Domain and subdomains"
            case .address: "IP address or network"
            case .localNetwork: "Local network"
            }
        }
    }

    init(rule: Rule?, onSave: @escaping (Rule) -> Void) {
        self.onSave = onSave
        isNew = rule == nil
        let rule = rule ?? Rule(process: .any, remote: .any, action: .deny, origin: .user)
        _rule = State(initialValue: rule)
        switch rule.remote {
        case .any, .blocklist:
            _remoteKind = State(initialValue: .any)
            _remoteText = State(initialValue: "")
        case .host(let host):
            _remoteKind = State(initialValue: .host)
            _remoteText = State(initialValue: host)
        case .domain(let domain):
            _remoteKind = State(initialValue: .domain)
            _remoteText = State(initialValue: domain)
        case .address(let address):
            _remoteKind = State(initialValue: .address)
            _remoteText = State(initialValue: address.description)
        case .network(let network):
            _remoteKind = State(initialValue: .address)
            _remoteText = State(initialValue: network.description)
        case .localNetwork:
            _remoteKind = State(initialValue: .localNetwork)
            _remoteText = State(initialValue: "")
        }
        _portsText = State(initialValue: RuleTransfer.formatPorts(rule.ports))
        switch rule.lifetime {
        case .until(let date):
            _lifetimeKind = State(initialValue: .until)
            _expiry = State(initialValue: date)
        case .untilRestart:
            _lifetimeKind = State(initialValue: .untilRestart)
            _expiry = State(initialValue: .now + 86_400)
        case .untilLogout:
            _lifetimeKind = State(initialValue: .untilLogout)
            _expiry = State(initialValue: .now + 86_400)
        case .untilQuit:
            _lifetimeKind = State(initialValue: .untilQuit)
            _expiry = State(initialValue: .now + 86_400)
        case .forever:
            _lifetimeKind = State(initialValue: .forever)
            _expiry = State(initialValue: .now + 86_400)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Action", selection: $rule.action) {
                        Label("Allow", systemImage: Theme.symbol(for: .allow)).tag(RuleAction.allow)
                        Label("Deny", systemImage: Theme.symbol(for: .deny)).tag(RuleAction.deny)
                    }
                    .pickerStyle(.segmented)
                    processPicker
                    Picker("Direction", selection: $rule.direction) {
                        Text("Outgoing").tag(Direction.outbound)
                        Text("Incoming").tag(Direction.inbound)
                        Text("Both").tag(Direction.any)
                    }
                }
                Section {
                    Picker("Server", selection: $remoteKind) {
                        ForEach(RemoteKind.allCases) { Text($0.title).tag($0) }
                    }
                    if remoteKind == .host || remoteKind == .domain || remoteKind == .address {
                        TextField(remotePlaceholder, text: $remoteText, prompt: Text(remotePlaceholder))
                            .textContentType(.URL)
                        if let error = remoteError {
                            Text(error).font(.caption).foregroundStyle(Theme.deny)
                        }
                    }
                    TextField("Ports", text: $portsText, prompt: Text("Any port, or e.g. 443, 8000-8100"))
                    Picker("Protocol", selection: $rule.transport) {
                        Text("TCP and UDP").tag(TransportProtocol.any)
                        Text("TCP").tag(TransportProtocol.tcp)
                        Text("UDP").tag(TransportProtocol.udp)
                    }
                }
                Section {
                    Picker("Profile", selection: $rule.profileID) {
                        Text("All profiles").tag(UUID?.none)
                        ForEach(model.profiles) { profile in
                            Text(profile.name).tag(Optional(profile.id))
                        }
                    }
                    Picker("Group", selection: $rule.groupID) {
                        Text("None").tag(UUID?.none)
                        ForEach(model.ruleGroups.filter { $0.subscription == nil }) { group in
                            Text(group.name).tag(Optional(group.id))
                        }
                    }
                    Picker("Lifetime", selection: $lifetimeKind) {
                        Text("Forever").tag(LifetimeKind.forever)
                        Text("Until a date").tag(LifetimeKind.until)
                        Text("Until the Mac restarts").tag(LifetimeKind.untilRestart)
                        Text("Until you log out").tag(LifetimeKind.untilLogout)
                        if rule.lifetime.isUntilQuit {
                            Text("Until the app quits").tag(LifetimeKind.untilQuit)
                        }
                    }
                    if lifetimeKind == .until {
                        DatePicker("Expires at", selection: $expiry, in: Date.now...)
                    }
                    TextField("Note", text: $rule.note, prompt: Text("Why this rule exists (optional)"), axis: .vertical)
                        .lineLimit(1...3)
                }
            }
            .formStyle(.grouped)
            .disabled(isSubscribed)
            if isSubscribed {
                Label("This rule comes from the “\(model.group(withID: rule.groupID)?.name ?? "")” subscription and updates with it, so it can't be edited here.", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            }

            VStack(alignment: .leading, spacing: 6) {
                if let built {
                    Text(model.describe(built))
                        .font(.callout.weight(.medium))
                    ForEach(issues, id: \.self) { issue in
                        Label(issue, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.pending)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Create Rule" : "Save") {
                    if let built {
                        onSave(built)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(built == nil || isSubscribed)
            }
            .padding(16)
        }
        .frame(width: 520)
        .fileImporter(isPresented: $choosingApp, allowedContentTypes: [.application, .unixExecutable, .executable]) { result in
            guard let url = try? result.get(), let identity = CodeSignature.identity(forPath: url.path) else { return }
            setProcess(identity)
        }
    }

    private var processPicker: some View {
        LabeledContent("Process") {
            Menu {
                Button("Any Process") {
                    rule.process = .any
                    rule.processName = nil
                    rule.processPath = nil
                }
                Divider()
                Section("Recently Active") {
                    ForEach(recentProcesses, id: \.key) { process in
                        Button {
                            setProcess(process)
                        } label: {
                            Label {
                                Text(ProcessPresentation.name(for: process))
                            } icon: {
                                Image(nsImage: ProcessPresentation.icon(for: process))
                            }
                        }
                    }
                }
                Divider()
                Button("Choose…") { choosingApp = true }
            } label: {
                if case .any = rule.process {
                    Text("Any process")
                } else {
                    Text(rule.processName ?? rule.process.keyDescription)
                }
            }
            .fixedSize()
        }
    }

    private var recentProcesses: [ProcessIdentity] {
        var seen = Set<ProcessKey>()
        return model.connections.values
            .sorted { $0.lastSeen > $1.lastSeen }
            .map(\.process)
            .filter { seen.insert($0.key).inserted }
            .prefix(15)
            .map { $0 }
    }

    private func setProcess(_ process: ProcessIdentity) {
        rule.process = .process(process.key)
        rule.processName = ProcessPresentation.name(for: process)
        rule.processPath = process.bundlePath ?? process.path
    }

    private var remotePlaceholder: String {
        switch remoteKind {
        case .host: "api.example.com"
        case .domain: "example.com"
        case .address: "203.0.113.4 or 10.0.0.0/8"
        default: ""
        }
    }

    private var remote: RemoteMatcher? {
        let text = remoteText.trimmingCharacters(in: .whitespaces)
        switch remoteKind {
        case .any: return .any
        case .localNetwork: return .localNetwork
        case .host:
            if let address = IPAddress(text) { return .address(address) }
            let host = RemoteMatcher.normalize(text)
            return BlocklistParser.isValidHostname(host) || (!host.isEmpty && !host.contains(" ") && !host.contains(".")) ? .host(host) : nil
        case .domain:
            let domain = RemoteMatcher.normalize(text)
            return BlocklistParser.isValidHostname(domain) ? .domain(domain) : nil
        case .address:
            guard let network = IPNetwork(text) else { return nil }
            return network.prefixLength == network.address.bitWidth ? .address(network.address) : .network(network)
        }
    }

    private var remoteError: String? {
        guard !remoteText.isEmpty, remote == nil else { return nil }
        return remoteKind == .address
            ? String(localized: "That doesn't look like a valid address or network.")
            : String(localized: "That doesn't look like a valid host name.")
    }

    private var built: Rule? {
        guard let remote else { return nil }
        if case .blocklist = rule.remote { return nil }
        var result = rule
        result.remote = remote
        result.ports = RuleTransfer.parsePorts(portsText)
        let session = Session.current
        result.lifetime = switch lifetimeKind {
        case .forever: .forever
        case .until: .until(expiry)
        case .untilRestart: .untilRestart(bootTime: session.bootTime)
        case .untilLogout: .untilLogout(session: session.loginSession)
        case .untilQuit: rule.lifetime
        }
        return result
    }

    private var issues: [String] {
        guard let built else { return [] }
        let others = model.rules.filter { $0.id != built.id } + [built]
        return RuleAnalysis.issues(for: built, in: others).map { RuleIssueText.describe($0, rules: others, model: model) }
    }
}

private extension ProcessMatcher {
    var keyDescription: String {
        switch self {
        case .any: "Any"
        case .process(let key): key.description
        }
    }
}

private extension RuleLifetime {
    var isUntilQuit: Bool {
        if case .untilQuit = self { return true }
        return false
    }
}
