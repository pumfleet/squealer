import AppKit
import SquealerKit
import SwiftUI

/// Asks which profile to use the first time the Mac joins a Wi-Fi network, like Little Snitch's
/// "new network" alert.
@MainActor
final class NetworkPromptController {
    private let model: AppModel
    private var panel: AlertPanel?

    init(model: AppModel) {
        self.model = model
    }

    func show(ssid: String) {
        let view = NetworkPromptView(ssid: ssid) { [weak self] in self?.close() }
            .environment(model)
        let hosting = NSHostingView(rootView: view)
        let panel = panel ?? AlertPanel()
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        if let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            panel.anchor = NSPoint(x: visible.maxX - 14, y: visible.maxY - 10)
            panel.setFrame(panel.frame, display: false)
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func close() {
        panel?.orderOut(nil)
    }
}

private struct NetworkPromptView: View {
    @Environment(AppModel.self) private var model
    var ssid: String
    var dismiss: () -> Void
    @State private var selection: UUID?
    @State private var remember = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "wifi")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Theme.brand.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("New network").font(.caption).foregroundStyle(.secondary)
                    Text(ssid).font(.title3.weight(.semibold)).lineLimit(1)
                }
            }
            Text("Which profile should Squealer use here?")
                .font(.callout)
            Picker("Profile", selection: $selection) {
                Label("Default", systemImage: "circle.dashed").tag(UUID?.none)
                ForEach(model.profiles) { profile in
                    Label(profile.name, systemImage: profile.symbol).tag(Optional(profile.id))
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Toggle("Always use it on “\(ssid)”", isOn: $remember)
                .disabled(selection == nil)
            HStack {
                Button("Not Now") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use Profile") {
                    model.activateProfile(selection)
                    if remember, let id = selection, var profile = model.profiles.first(where: { $0.id == id }) {
                        var ssids: [String] = []
                        if case .wifi(let existing) = profile.autoSwitch { ssids = existing }
                        profile.autoSwitch = .wifi(ssids: ssids + [ssid])
                        model.save(profile)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 340)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator.opacity(0.6)))
        .onAppear { selection = model.settings.activeProfileID }
    }
}
