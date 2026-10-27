import CoreWLAN
import SquealerKit
import SwiftUI

struct ProfilesView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Profile?
    @AppStorage("profiles.askOnNewNetwork") private var askOnNewNetwork = true

    var body: some View {
        List {
            Section {
                ProfileRow(
                    name: String(localized: "Default"),
                    symbol: "circle.dashed",
                    detail: String(localized: "Only rules that apply to all profiles"),
                    ruleCount: model.rules.filter { $0.profileID == nil }.count,
                    isActive: model.settings.activeProfileID == nil
                ) {
                    model.activateProfile(nil)
                }
            } footer: {
                Text("Rules marked “All profiles” apply everywhere. A profile adds its own rules on top, so you can be stricter on public Wi‑Fi or more relaxed at home.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Ask which profile to use when joining a new Wi‑Fi network", isOn: $askOnNewNetwork)
            }
            Section("Profiles") {
                ForEach(model.profiles) { profile in
                    ProfileRow(
                        name: profile.name,
                        symbol: profile.symbol,
                        detail: autoSwitchDescription(profile.autoSwitch),
                        ruleCount: model.rules.filter { $0.profileID == profile.id }.count,
                        isActive: model.settings.activeProfileID == profile.id
                    ) {
                        model.activateProfile(profile.id)
                    }
                    .contextMenu {
                        Button("Edit…") { editing = profile }
                        Button("Delete", role: .destructive) { model.deleteProfile(profile.id) }
                    }
                }
            }
        }
        .listStyle(.inset)
        .navigationTitle("Profiles")
        .toolbar {
            Button {
                editing = Profile(name: "")
            } label: { Label("New Profile", systemImage: "plus") }
        }
        .sheet(item: $editing) { profile in
            ProfileEditor(profile: profile)
        }
    }

    private func autoSwitchDescription(_ condition: AutoSwitchCondition?) -> String {
        switch condition {
        case .wifi(let ssids): String(localized: "Automatic on Wi‑Fi \(ssids.joined(separator: ", "))")
        case .interfaceType(let kind): String(localized: "Automatic on \(kind.title)")
        case nil: String(localized: "Manual")
        }
    }
}

private struct ProfileRow: View {
    var name: String
    var symbol: String
    var detail: String
    var ruleCount: Int
    var isActive: Bool
    var activate: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(isActive ? Color.white : Theme.brand)
                .frame(width: 34, height: 34)
                .background(isActive ? AnyShapeStyle(Theme.brand.gradient) : AnyShapeStyle(Theme.brand.opacity(0.12)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(ruleCount) rules").font(.caption).foregroundStyle(.secondary)
            if isActive {
                Pill(text: "Active", symbol: "checkmark", color: Theme.allow)
            } else {
                Button("Activate", action: activate).controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ProfileEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var profile: Profile
    @State private var trigger: Trigger
    @State private var ssids: String
    @State private var interface: InterfaceKind

    enum Trigger: String, CaseIterable, Identifiable {
        case manual, wifi, interface
        var id: Self { self }
    }

    private static let symbols = [
        "house.fill", "building.2.fill", "cup.and.saucer.fill", "airplane", "lock.shield.fill",
        "figure.walk", "briefcase.fill", "moon.fill", "gamecontroller.fill", "graduationcap.fill",
    ]

    init(profile: Profile) {
        _profile = State(initialValue: profile)
        switch profile.autoSwitch {
        case .wifi(let names):
            _trigger = State(initialValue: .wifi)
            _ssids = State(initialValue: names.joined(separator: ", "))
            _interface = State(initialValue: .wifi)
        case .interfaceType(let kind):
            _trigger = State(initialValue: .interface)
            _ssids = State(initialValue: "")
            _interface = State(initialValue: kind)
        case nil:
            _trigger = State(initialValue: .manual)
            _ssids = State(initialValue: "")
            _interface = State(initialValue: .wifi)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $profile.name, prompt: Text("Home, Work, Café…"))
                LabeledContent("Symbol") {
                    HStack(spacing: 4) {
                        ForEach(Self.symbols, id: \.self) { symbol in
                            Button {
                                profile.symbol = symbol
                            } label: {
                                Image(systemName: symbol)
                                    .frame(width: 26, height: 26)
                                    .background(profile.symbol == symbol ? Theme.brand.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Picker("Switch to this profile", selection: $trigger) {
                    Text("Manually").tag(Trigger.manual)
                    Text("On specific Wi‑Fi networks").tag(Trigger.wifi)
                    Text("On a type of connection").tag(Trigger.interface)
                }
                if trigger == .wifi {
                    TextField("Network names", text: $ssids, prompt: Text("Comma-separated"))
                    if let current = CWWiFiCurrentSSID.value, !ssids.contains(current) {
                        Button("Add “\(current)”") {
                            ssids = ssids.isEmpty ? current : ssids + ", " + current
                        }
                        .buttonStyle(.link)
                    }
                    Text("Reading the Wi‑Fi name requires Location Services permission.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if trigger == .interface {
                    Picker("Connection", selection: $interface) {
                        ForEach(InterfaceKind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    var saved = profile
                    saved.name = saved.name.trimmingCharacters(in: .whitespaces)
                    switch trigger {
                    case .manual: saved.autoSwitch = nil
                    case .wifi: saved.autoSwitch = .wifi(ssids: ssids.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
                    case .interface: saved.autoSwitch = .interfaceType(interface)
                    }
                    model.save(saved)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(profile.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 480)
    }
}

extension InterfaceKind {
    var title: String {
        switch self {
        case .wifi: String(localized: "Wi‑Fi")
        case .wired: String(localized: "Ethernet")
        case .cellular: String(localized: "Cellular / iPhone hotspot")
        case .vpn: String(localized: "VPN")
        }
    }
}

enum CWWiFiCurrentSSID {
    static var value: String? { CWWiFiClient.shared().interface()?.ssid() }
}
