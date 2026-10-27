import SquealerKit
import SwiftUI
import UniformTypeIdentifiers

struct RuleGroupsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: RuleGroup?
    @State private var subscribing = false
    @State private var deleting: RuleGroup?
    @State private var refreshing = Set<UUID>()
    @State private var exporting: RuleGroup?

    var body: some View {
        Group {
            if model.ruleGroups.isEmpty {
                ContentUnavailableView {
                    Label("No Rule Groups", systemImage: "folder")
                } description: {
                    Text("Group related rules so you can switch them on and off together, or subscribe to rule sets other people maintain. Little Snitch rule groups (.lsrules) work too.")
                } actions: {
                    HStack {
                        Button("New Group…") { editing = RuleGroup(name: "") }
                        Button("Subscribe…") { subscribing = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                List {
                    let own = model.ruleGroups.filter { $0.subscription == nil }.sorted { $0.name < $1.name }
                    let subscribed = model.ruleGroups.filter { $0.subscription != nil }.sorted { $0.name < $1.name }
                    if !own.isEmpty {
                        Section("Your Groups") {
                            ForEach(own) { row($0) }
                        }
                    }
                    if !subscribed.isEmpty {
                        Section("Subscriptions") {
                            ForEach(subscribed) { row($0) }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Rule Groups")
        .toolbar {
            ToolbarItemGroup {
                Button { subscribing = true } label: { Label("Subscribe", systemImage: "antenna.radiowaves.left.and.right") }
                    .help("Subscribe to a rule group by URL")
                Button { editing = RuleGroup(name: "") } label: { Label("New Group", systemImage: "folder.badge.plus") }
                    .help("New rule group")
            }
        }
        .sheet(item: $editing) { group in
            GroupEditor(group: group)
        }
        .sheet(isPresented: $subscribing) {
            SubscribeSheet()
        }
        .confirmationDialog(
            "Delete “\(deleting?.name ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { group in
            Button("Delete Group and Its Rules", role: .destructive) { model.deleteGroup(group.id, deleteRules: true) }
            if group.subscription == nil {
                Button("Delete Group, Keep Rules") { model.deleteGroup(group.id, deleteRules: false) }
            }
        }
        .fileExporter(
            isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
            document: GroupDocument(group: exporting, rules: model.rules.filter { $0.groupID == exporting?.id }),
            contentType: UTType(filenameExtension: "lsrules") ?? .json,
            defaultFilename: "\(exporting?.name ?? "Rules").lsrules"
        ) { _ in }
    }

    private func row(_ group: RuleGroup) -> some View {
        let count = model.rules.filter { $0.groupID == group.id }.count
        return HStack(spacing: 12) {
            Toggle("Enabled", isOn: Binding(get: { group.isEnabled }, set: { enabled in
                var updated = group
                updated.isEnabled = enabled
                model.save(updated)
            }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            Image(systemName: group.subscription == nil ? "folder.fill" : "antenna.radiowaves.left.and.right")
                .foregroundStyle(Theme.brand)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name.isEmpty ? String(localized: "Untitled") : group.name).fontWeight(.medium)
                if !group.note.isEmpty {
                    Text(group.note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let subscription = group.subscription {
                    Text(subscription.url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let error = subscription.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.deny)
                    }
                    if !subscription.skippedProcesses.isEmpty {
                        Text("^[\(subscription.skippedProcesses.count) rule](inflect: true) skipped for apps that aren't installed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help(subscription.skippedProcesses.joined(separator: "\n"))
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("^[\(count) rule](inflect: true)").font(.callout.monospacedDigit())
                if let subscription = group.subscription {
                    Text(subscription.lastUpdated.map { String(localized: "Updated \(Format.relative($0))") } ?? String(localized: "Not downloaded yet"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if refreshing.contains(group.id) {
                ProgressView().controlSize(.small)
            }
            Menu {
                Button("Show Rules") {
                    NavigationModel.shared.ruleFilterGroup = group.id
                    NavigationModel.shared.section = .rules
                }
                if group.subscription != nil {
                    Button("Update Now") { refresh(group.id) }
                } else {
                    Button("Edit…") { editing = group }
                    Button("Export as Little Snitch Rule Group…") { exporting = group }
                        .disabled(count == 0)
                }
                Divider()
                Button("Delete…", role: .destructive) { deleting = group }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Actions for \(group.name)")
        }
        .padding(.vertical, 4)
    }

    private func refresh(_ id: UUID) {
        refreshing.insert(id)
        Task {
            await model.refreshGroup(id)
            refreshing.remove(id)
        }
    }
}

private struct GroupEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var group: RuleGroup

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $group.name, prompt: Text("e.g. Developer tools"))
                TextField("Description", text: $group.note, prompt: Text("Optional"), axis: .vertical)
                    .lineLimit(2...4)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.save(group)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(group.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 420)
    }
}

private struct SubscribeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var name = ""
    @State private var interval: TimeInterval = 86_400

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("URL", text: $url, prompt: Text("https://example.com/rules.lsrules"))
                    TextField("Name", text: $name, prompt: Text("Taken from the file if empty"))
                    Picker("Check for updates", selection: $interval) {
                        Text("Every 6 Hours").tag(TimeInterval(6 * 3_600))
                        Text("Daily").tag(TimeInterval(86_400))
                        Text("Weekly").tag(TimeInterval(7 * 86_400))
                    }
                } footer: {
                    Text("Subscribed rules can allow as well as deny, so only subscribe to sources you trust. Rules for apps that aren't installed on this Mac are skipped.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Subscribe") {
                    guard let parsed = subscriptionURL else { return }
                    model.save(RuleGroup(name: name, subscription: RuleGroup.Subscription(url: parsed, updateInterval: interval)))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(subscriptionURL == nil)
            }
            .padding(16)
        }
        .frame(width: 480)
    }

    private var subscriptionURL: URL? {
        guard let parsed = URL(string: url.trimmingCharacters(in: .whitespaces)), parsed.scheme == "https", parsed.host() != nil else { return nil }
        return parsed
    }
}

struct GroupDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var group: RuleGroup?
    var rules: [Rule]

    init(group: RuleGroup?, rules: [Rule]) {
        self.group = group
        self.rules = rules
    }

    init(configuration: ReadConfiguration) throws {
        group = nil
        rules = []
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try LittleSnitchFormat.export(rules, name: group?.name ?? "Rules", description: group?.note ?? ""))
    }
}
