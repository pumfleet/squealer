import SquealerKit
import SwiftUI
import UniformTypeIdentifiers

struct RulesView: View {
    @Environment(AppModel.self) private var model
    @Bindable private var navigation = NavigationModel.shared

    @State private var search = ""
    @State private var selection = Set<Rule.ID>()
    @State private var sortOrder = [KeyPathComparator(\RuleRow.modifiedAt, order: .reverse)]
    @State private var actionFilter: RuleAction?
    @State private var originFilter: RuleOrigin?
    @State private var approvalOnly = false
    @State private var exportFormat = ExportFormat.squealer
    @State private var editing: EditorTarget?
    @State private var importing = false
    @State private var exporting = false
    @State private var transferMessage: String?

    enum ExportFormat {
        case squealer
        case littleSnitch
    }

    private struct EditorTarget: Identifiable {
        var rule: Rule?
        var id: UUID { rule?.id ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")! }
    }

    var body: some View {
        let rows = filteredRows
        Group {
            if model.rules.isEmpty {
                EmptyStateView(
                    title: "No Rules Yet",
                    symbol: "list.bullet.rectangle",
                    message: "Rules are created when you answer connection alerts. You can also add them yourself with the + button."
                )
            } else if rows.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                table(rows)
            }
        }
        .navigationTitle("Rules")
        .navigationSubtitle(String(localized: "\(rows.count) of \(model.rules.count)"))
        .searchable(text: $search, placement: .toolbar, prompt: "Search rules")
        .toolbar { toolbar }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if !model.unapprovedRules.isEmpty {
                    approvalBar
                }
                if let key = navigation.ruleFilterProcess {
                    processFilterBar(key)
                }
                if let group = model.group(withID: navigation.ruleFilterGroup) {
                    filterBar(String(localized: "Showing rules in \(group.name)")) { navigation.ruleFilterGroup = nil }
                }
            }
        }
        .sheet(item: $editing) { target in
            RuleEditor(rule: target.rule) { rule in
                model.save([rule])
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, UTType(filenameExtension: "lsrules") ?? .json]) { result in
            importRules(result)
        }
        .fileExporter(
            isPresented: $exporting,
            document: RulesDocument(rules: exportedRules, format: exportFormat),
            contentType: exportFormat == .littleSnitch ? (UTType(filenameExtension: "lsrules") ?? .json) : .json,
            defaultFilename: exportFormat == .littleSnitch ? "Squealer Rules.lsrules" : "Squealer Rules"
        ) { _ in }
        .alert("Import", isPresented: Binding(get: { transferMessage != nil }, set: { if !$0 { transferMessage = nil } })) {
            Button("OK") { transferMessage = nil }
        } message: {
            Text(transferMessage ?? "")
        }
        .onDeleteCommand {
            model.deleteRules(selection)
            selection.removeAll()
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Menu {
                Picker("Action", selection: $actionFilter) {
                    Text("All Actions").tag(RuleAction?.none)
                    Label("Allow", systemImage: Theme.symbol(for: .allow)).tag(Optional(RuleAction.allow))
                    Label("Deny", systemImage: Theme.symbol(for: .deny)).tag(Optional(RuleAction.deny))
                }
                Toggle("Needs Approval", isOn: $approvalOnly)
                if !model.ruleGroups.isEmpty {
                    Picker("Group", selection: $navigation.ruleFilterGroup) {
                        Text("All Groups").tag(UUID?.none)
                        ForEach(model.ruleGroups) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                Picker("Created By", selection: $originFilter) {
                    Text("Anyone").tag(RuleOrigin?.none)
                    Text("Alerts").tag(Optional(RuleOrigin.alert))
                    Text("You").tag(Optional(RuleOrigin.user))
                    Text("Imported").tag(Optional(RuleOrigin.imported))
                }
            } label: {
                Label("Filter", systemImage: actionFilter == nil && originFilter == nil && !approvalOnly ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .help("Filter rules")

            Menu {
                Button("Import Rules…") { importing = true }
                Button("Export Rules…") { exportFormat = .squealer; exporting = true }
                    .disabled(model.rules.isEmpty)
                Button("Export for Little Snitch…") { exportFormat = .littleSnitch; exporting = true }
                    .disabled(model.rules.isEmpty)
            } label: {
                Label("Import & Export", systemImage: "square.and.arrow.up.on.square")
            }

            Button {
                editing = EditorTarget(rule: nil)
            } label: {
                Label("New Rule", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
            .help("New rule")
        }
    }

    /// Rules exported are what's on screen, so filtering first exports a subset.
    private var exportedRules: [Rule] {
        let ids = Set(filteredRows.map(\.id))
        return model.rules.filter { ids.contains($0.id) }
    }

    private var approvalBar: some View {
        HStack {
            Image(systemName: "checkmark.seal").foregroundStyle(Theme.pending)
            Text("^[\(model.unapprovedRules.count) rule](inflect: true) added automatically or imported. Check them, then approve.")
                .font(.callout)
            Spacer()
            Button(approvalOnly ? "Show All" : "Show") { approvalOnly.toggle() }
                .controlSize(.small)
            Button("Approve All") { model.approve(Set(model.unapprovedRules.map(\.id))) }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func filterBar(_ text: String, clear: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(Theme.brand)
            Text(text).font(.callout)
            Spacer()
            Button("Show All Rules", action: clear).controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func processFilterBar(_ key: ProcessKey) -> some View {
        HStack {
            Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(Theme.brand)
            Text("Showing rules for \(model.rules.first { $0.process == .process(key) }?.processName ?? key.signingID ?? key.description)")
                .font(.callout)
            Spacer()
            Button("Show All Rules") { navigation.ruleFilterProcess = nil }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var filteredRows: [RuleRow] {
        let query = search.lowercased()
        var rows = model.rules.compactMap { rule -> RuleRow? in
            if let key = navigation.ruleFilterProcess, rule.process != .process(key), rule.via != key { return nil }
            if let actionFilter, rule.action != actionFilter { return nil }
            if let originFilter, rule.origin != originFilter { return nil }
            if approvalOnly, rule.isApproved { return nil }
            if let group = navigation.ruleFilterGroup, rule.groupID != group { return nil }
            var row = RuleRow(rule: rule, description: model.describe(rule), profile: rule.profileID.flatMap { id in model.profiles.first { $0.id == id }?.name })
            row.groupName = model.group(withID: rule.groupID)?.name ?? ""
            if !query.isEmpty, !row.searchText.contains(query) { return nil }
            return row
        }
        rows.sort(using: sortOrder)
        return rows
    }

    private func table(_ rows: [RuleRow]) -> some View {
        let issues = issuesByRule(rows)
        return Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("On") { row in
                Toggle("Enabled", isOn: Binding(get: { row.rule.isEnabled }, set: { enabled in
                    var rule = row.rule
                    rule.isEnabled = enabled
                    model.save([rule])
                }))
                .labelsHidden()
                .toggleStyle(.checkbox)
            }
            .width(28)

            TableColumn("Action", value: \.actionOrder) { row in
                Image(systemName: Theme.symbol(for: row.rule.action))
                    .foregroundStyle(Theme.color(for: row.rule.action))
                    .help(row.rule.action == .allow ? "Allow" : "Deny")
            }
            .width(44)

            TableColumn("Process", value: \.processName) { row in
                HStack(spacing: 6) {
                    if case .any = row.rule.process {
                        Image(systemName: "square.stack.3d.up").foregroundStyle(.secondary).frame(width: 18)
                    } else {
                        AppIcon(process: row.rule.processPath.map { ProcessIdentity(path: $0, signer: .developerID, bundlePath: $0.hasSuffix(".app") ? $0 : nil) }, size: 18)
                    }
                    Text(row.processName).lineLimit(1)
                    if !row.rule.isApproved {
                        Circle().fill(Theme.pending).frame(width: 6, height: 6)
                            .help("Needs approval")
                            .accessibilityLabel("Needs approval")
                    }
                    if let issue = issues[row.id] {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.pending)
                            .help(issue)
                    }
                }
            }
            .width(min: 160, ideal: 200)

            TableColumn("Server", value: \.remoteText) { row in
                Text(row.remoteText).lineLimit(1).truncationMode(.middle)
            }
            .width(min: 140, ideal: 220)

            TableColumn("Port", value: \.portText) { row in
                Text(row.portText).foregroundStyle(row.rule.ports == .any ? .tertiary : .primary)
            }
            .width(min: 60, ideal: 90)

            TableColumn("Direction", value: \.directionText) { row in
                Text(row.directionText).foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)

            TableColumn("Scope", value: \.scopeText) { row in
                HStack(spacing: 4) {
                    if let profile = row.profile {
                        Pill(text: "\(profile)", symbol: "person.crop.square", color: Theme.brand)
                    }
                    if row.rule.lifetime != .forever {
                        Pill(text: "\(RuleText.lifetime(row.rule.lifetime) ?? "")", symbol: "clock", color: Theme.pending)
                    }
                    if row.profile == nil && row.rule.lifetime == .forever {
                        Text("Always").foregroundStyle(.tertiary)
                    }
                }
            }
            .width(min: 80, ideal: 120)

            TableColumn("Group", value: \.groupName) { row in
                if let group = model.group(withID: row.rule.groupID) {
                    Label(group.name, systemImage: group.subscription == nil ? "folder" : "antenna.radiowaves.left.and.right")
                        .lineLimit(1)
                        .foregroundStyle(group.isEnabled ? .primary : .tertiary)
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .width(min: 80, ideal: 120)

            TableColumn("Modified", value: \.modifiedAt) { row in
                Text(row.modifiedAt.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 100)
        }
        .contextMenu(forSelectionType: Rule.ID.self) { ids in
            if ids.count == 1, let id = ids.first, let rule = model.rule(withID: id) {
                Button(rule.origin == .subscription ? "View…" : "Edit…") { editing = EditorTarget(rule: rule) }
                Button("Duplicate") {
                    var copy = rule
                    copy.id = UUID()
                    copy.createdAt = .now
                    editing = EditorTarget(rule: copy)
                }
                Divider()
            }
            let rules = ids.compactMap(model.rule(withID:))
            if rules.contains(where: { !$0.isApproved }) {
                Button("Approve") { model.approve(ids) }
            }
            if !model.ruleGroups.isEmpty {
                Menu("Move to Group") {
                    Button("No Group") { model.save(rules.map { var rule = $0; rule.groupID = nil; return rule }) }
                    Divider()
                    ForEach(model.ruleGroups.filter { $0.subscription == nil }) { group in
                        Button(group.name) { model.save(rules.map { var rule = $0; rule.groupID = group.id; return rule }) }
                    }
                }
                .disabled(rules.contains { $0.origin == .subscription })
            }
            Button(rules.allSatisfy(\.isEnabled) ? "Disable" : "Enable") {
                let enable = !rules.allSatisfy(\.isEnabled)
                model.save(rules.map { var rule = $0; rule.isEnabled = enable; return rule })
            }
            Button("Change to \(rules.first?.action == .allow ? "Deny" : "Allow")") {
                model.save(rules.map { var rule = $0; rule.action = rule.action == .allow ? .deny : .allow; return rule })
            }
            Divider()
            Button("Delete", role: .destructive) {
                model.deleteRules(ids)
                selection.subtract(ids)
            }
        } primaryAction: { ids in
            if let id = ids.first, let rule = model.rule(withID: id) {
                editing = EditorTarget(rule: rule)
            }
        }
    }

    private func issuesByRule(_ rows: [RuleRow]) -> [UUID: String] {
        guard model.rules.count <= 3_000 else { return [:] }
        var result: [UUID: String] = [:]
        for row in rows {
            guard let issue = RuleAnalysis.issues(for: row.rule, in: model.rules).first else { continue }
            result[row.id] = RuleIssueText.describe(issue, rules: model.rules, model: model)
        }
        return result
    }

    private func importRules(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let imported = try RuleTransfer.importRules(from: Data(contentsOf: url))
            model.save(imported.rules)
            var message = String(localized: "Imported \(imported.rules.count) rules.")
            if !imported.skipped.isEmpty {
                message += " " + String(localized: "Skipped rules for apps that aren't installed: \(imported.skipped.joined(separator: ", "))")
            }
            transferMessage = message
        } catch {
            transferMessage = error.localizedDescription
        }
    }
}

struct RuleRow: Identifiable {
    var rule: Rule
    var description: String
    var profile: String?

    var id: UUID { rule.id }
    var modifiedAt: Date { rule.modifiedAt }
    var actionOrder: Int { rule.action == .allow ? 0 : 1 }
    var processName: String { RuleText.process(rule) }
    var remoteText: String { RuleText.remote(rule.remote) }
    var portText: String {
        let ports = RuleTransfer.formatPorts(rule.ports)
        let transport = rule.transport == .any ? "" : " \(rule.transport.rawValue.uppercased())"
        return (ports.isEmpty ? String(localized: "Any") : ports) + transport
    }
    var directionText: String {
        switch rule.direction {
        case .outbound: String(localized: "Out")
        case .inbound: String(localized: "In")
        case .any: String(localized: "Both")
        }
    }
    var scopeText: String { (profile ?? "") + (RuleText.lifetime(rule.lifetime) ?? "") }
    var groupName: String = ""
    var searchText: String { (description + " " + rule.note + " " + (rule.processPath ?? "")).lowercased() }
}

enum RuleIssueText {
    @MainActor
    static func describe(_ issue: RuleIssue, rules: [Rule], model: AppModel) -> String {
        func sentence(_ id: UUID) -> String {
            rules.first { $0.id == id }.map(model.describe) ?? String(localized: "another rule")
        }
        switch issue {
        case .duplicate(let id): return String(localized: "Duplicate of “\(sentence(id))”")
        case .overriddenBy(let id): return String(localized: "Never applies: “\(sentence(id))” takes precedence")
        case .redundant(let id): return String(localized: "Already covered by “\(sentence(id))”")
        }
    }
}

struct RulesDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var rules: [Rule]
    var format: RulesView.ExportFormat = .squealer

    init(rules: [Rule], format: RulesView.ExportFormat = .squealer) {
        self.rules = rules
        self.format = format
    }

    init(configuration: ReadConfiguration) throws {
        rules = try RuleTransfer.importRules(from: configuration.file.regularFileContents ?? Data()).rules
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        switch format {
        case .squealer: FileWrapper(regularFileWithContents: try RuleTransfer.export(rules))
        case .littleSnitch: FileWrapper(regularFileWithContents: try LittleSnitchFormat.export(rules, name: "Squealer Rules"))
        }
    }
}
