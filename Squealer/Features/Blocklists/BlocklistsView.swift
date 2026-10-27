import SquealerKit
import SwiftUI

struct BlocklistCatalogEntry: Identifiable, Sendable {
    var name: String
    var summary: LocalizedStringResource
    var url: URL
    var format: BlocklistFormat
    var id: URL { url }

    static let all: [BlocklistCatalogEntry] = [
        BlocklistCatalogEntry(name: "HaGeZi Light", summary: "Ads, tracking and metrics with almost no breakage. A good first list.", url: URL(string: "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/light-onlydomains.txt")!, format: .domains),
        BlocklistCatalogEntry(name: "HaGeZi Pro", summary: "Broader ads and tracking coverage; occasionally blocks something you use.", url: URL(string: "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro-onlydomains.txt")!, format: .domains),
        BlocklistCatalogEntry(name: "HaGeZi Threat Intelligence", summary: "Malware, phishing, scams and command-and-control servers.", url: URL(string: "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/tif-onlydomains.txt")!, format: .domains),
        BlocklistCatalogEntry(name: "OISD Small", summary: "Ads and trackers, tuned to avoid breaking sites.", url: URL(string: "https://small.oisd.nl/")!, format: .adblock),
        BlocklistCatalogEntry(name: "OISD Big", summary: "OISD's comprehensive list of ads, trackers and malware.", url: URL(string: "https://big.oisd.nl/")!, format: .adblock),
        BlocklistCatalogEntry(name: "StevenBlack Unified", summary: "The classic consolidated hosts file of ad and malware hosts.", url: URL(string: "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts")!, format: .hosts),
        BlocklistCatalogEntry(name: "Peter Lowe's List", summary: "A small, long-maintained list of ad servers.", url: URL(string: "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext")!, format: .hosts),
    ]
}

struct BlocklistsView: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false
    @State private var refreshing = Set<UUID>()

    var body: some View {
        Group {
            if model.blocklists.isEmpty {
                ContentUnavailableView {
                    Label("No Blocklists", systemImage: "shield.checkered")
                } description: {
                    Text("Blocklists deny connections to known ad, tracking and malware servers for every app. Your own rules always take precedence.")
                } actions: {
                    Button("Add Blocklist…") { adding = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(model.blocklists.sorted { $0.name < $1.name }) { list in
                        BlocklistRow(list: list, isRefreshing: refreshing.contains(list.id)) {
                            refresh(list.id)
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .navigationTitle("Blocklists")
        .navigationSubtitle(String(localized: "\(model.blocklists.reduce(0) { $0 + ($1.isEnabled ? $1.entryCount : 0) }.formatted()) entries active"))
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.blocklists.forEach { refresh($0.id) }
                } label: { Label("Update All", systemImage: "arrow.clockwise") }
                    .disabled(model.blocklists.isEmpty)
                Button {
                    adding = true
                } label: { Label("Add Blocklist", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $adding) {
            AddBlocklistSheet()
        }
    }

    private func refresh(_ id: UUID) {
        refreshing.insert(id)
        Task {
            await model.refreshBlocklist(id)
            refreshing.remove(id)
        }
    }
}

private struct BlocklistRow: View {
    @Environment(AppModel.self) private var model
    var list: BlocklistSubscription
    var isRefreshing: Bool
    var refresh: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("Enabled", isOn: Binding(get: { list.isEnabled }, set: { enabled in
                var updated = list
                updated.isEnabled = enabled
                model.save(updated)
            }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 2) {
                Text(list.name).fontWeight(.medium)
                Text(list.url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let error = list.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.deny)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(list.entryCount.formatted()) entries")
                    .font(.callout.monospacedDigit())
                Text(list.lastUpdated.map { String(localized: "Updated \(Format.relative($0))") } ?? String(localized: "Not downloaded yet"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Menu {
                    Button("Update Now", action: refresh)
                    Picker("Update", selection: Binding(get: { list.updateInterval }, set: { interval in
                        var updated = list
                        updated.updateInterval = interval
                        model.save(updated)
                    })) {
                        Text("Every 6 Hours").tag(TimeInterval(6 * 3_600))
                        Text("Daily").tag(TimeInterval(86_400))
                        Text("Weekly").tag(TimeInterval(7 * 86_400))
                    }
                    if !model.profiles.isEmpty {
                        Menu("Use In") {
                            Toggle("All Profiles", isOn: Binding(get: { list.profileIDs == nil }, set: { all in
                                var updated = list
                                updated.profileIDs = all ? nil : []
                                model.save(updated)
                            }))
                            Divider()
                            ForEach(model.profiles) { profile in
                                Toggle(profile.name, isOn: Binding(get: { list.profileIDs?.contains(profile.id) ?? true }, set: { include in
                                    var updated = list
                                    var ids = updated.profileIDs ?? Set(model.profiles.map(\.id))
                                    if include { ids.insert(profile.id) } else { ids.remove(profile.id) }
                                    updated.profileIDs = ids
                                    model.save(updated)
                                }))
                            }
                        }
                    }
                    Divider()
                    Button("Remove", role: .destructive) { model.deleteBlocklist(list.id) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Actions for \(list.name)")
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.vertical, 4)
    }
}

private struct AddBlocklistSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var customURL = ""
    @State private var customName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add a Blocklist")
                .font(.title2.weight(.semibold))
                .padding([.horizontal, .top], 20)
            Text("Curated lists that are well maintained and safe to start with.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            List(BlocklistCatalogEntry.all) { entry in
                let added = model.blocklists.contains { $0.url == entry.url }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).fontWeight(.medium)
                        Text(entry.summary).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(added ? "Added" : "Add") {
                        model.save(BlocklistSubscription(name: entry.name, url: entry.url, format: entry.format))
                    }
                    .disabled(added)
                }
                .padding(.vertical, 3)
            }
            .listStyle(.inset)
            .frame(height: 300)

            Form {
                Section("Custom list") {
                    TextField("URL", text: $customURL, prompt: Text("https://example.com/hosts.txt"))
                    TextField("Name", text: $customName, prompt: Text("Optional"))
                    Text("Hosts files, plain domain lists, Adblock-style `||domain^` lists and Little Snitch rule groups are supported.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(height: 170)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Custom List") {
                    guard let url = customURL.url else { return }
                    model.save(BlocklistSubscription(name: customName.isEmpty ? (url.host() ?? url.absoluteString) : customName, url: url))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(customURL.url == nil)
            }
            .padding(20)
        }
        .frame(width: 520)
    }
}

private extension String {
    var url: URL? {
        guard let url = URL(string: trimmingCharacters(in: .whitespaces)), ["https", "http"].contains(url.scheme ?? ""), url.host() != nil else { return nil }
        return url
    }
}
