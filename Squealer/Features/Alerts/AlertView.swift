import SquealerKit
import SwiftUI

struct AlertStackView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedID: UUID?

    var body: some View {
        let alerts = model.alerts
        let index = selectedID.flatMap { id in alerts.firstIndex { $0.id == id } } ?? 0
        Group {
            if alerts.indices.contains(index) {
                AlertView(alert: alerts[index], position: index, total: alerts.count) { offset in
                    let next = (index + offset + alerts.count) % alerts.count
                    selectedID = alerts[next].id
                }
                .id(alerts[index].id)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: alerts.map(\.id))
    }
}

struct AlertView: View {
    @Environment(AppModel.self) private var model
    var alert: ConnectionAlert
    var position: Int
    var total: Int
    var navigate: (Int) -> Void

    @AppStorage("alert.remote") private var defaultRemoteScope: AlertScope.Remote = .domain
    @AppStorage("alert.ports") private var defaultPortScope: AlertScope.Ports = .any
    @AppStorage("alert.duration") private var defaultDuration: AlertScope.Duration = .forever
    // Choices start from the defaults in Settings and stay local to this alert.
    @State private var remoteChoice: AlertScope.Remote?
    @State private var portChoice: AlertScope.Ports?
    @State private var durationChoice: AlertScope.Duration?
    @State private var showDetails = false
    /// Ignores clicks and keys for a moment after the alert appears, so a click or Return meant for another
    /// window doesn't answer it.
    @State private var isArmed = false
    @State private var saveToProfile = false

    private var flow: FlowContext { alert.flow }
    private var isBrowser: Bool { KnownApps.isWebBrowser(flow.process) }

    private var remoteScope: AlertScope.Remote {
        remoteChoice ?? (isBrowser && flow.direction == .outbound ? .any : defaultRemoteScope)
    }
    private var portScope: AlertScope.Ports { portChoice ?? defaultPortScope }
    private var duration: AlertScope.Duration { durationChoice ?? defaultDuration }

    private var remoteBinding: Binding<AlertScope.Remote> {
        Binding(get: { remoteScope }, set: { remoteChoice = $0 })
    }
    private var portBinding: Binding<AlertScope.Ports> {
        Binding(get: { portScope }, set: { portChoice = $0 })
    }
    private var durationBinding: Binding<AlertScope.Duration> {
        Binding(get: { duration }, set: { durationChoice = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 14)
            destination
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            Divider()
            scopeControls
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            if showDetails {
                Divider()
                details
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
            }
            Divider()
            actions
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
        }
        .background(ActiveMaterial())
        .task {
            try? await Task.sleep(for: .milliseconds(700))
            isArmed = true
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            AppIcon(process: flow.process, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(ProcessPresentation.name(for: flow.process))
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    if alert.attempts > 1 {
                        Text("×\(alert.attempts)")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .help("Connection attempts waiting for this decision")
                    }
                }
                HStack(spacing: 6) {
                    SignerBadge(process: flow.process)
                    if let via = flow.via {
                        Text("via \(ProcessPresentation.name(for: via))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            if total > 1 {
                HStack(spacing: 2) {
                    Button { navigate(-1) } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("Previous alert")
                        .keyboardShortcut("[", modifiers: .command)
                    Text("\(position + 1) of \(total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button { navigate(1) } label: { Image(systemName: "chevron.right") }
                        .accessibilityLabel("Next alert")
                        .keyboardShortcut("]", modifiers: .command)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var destination: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(flow.direction == .inbound ? "wants to accept a connection from" : "wants to connect to")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text(flow.remoteDisplayName)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(flow.remoteDisplayName)
                Spacer(minLength: 8)
                Pill(text: "\(Format.port(flow.direction == .inbound ? flow.localPort : flow.remotePort, transport: flow.transport))", symbol: nil, color: .secondary)
            }
            HStack(spacing: 8) {
                if let service = flow.remoteHostname.flatMap(KnowledgeBase.service(for:)) {
                    ServiceBadge(service: service)
                }
                GeoLabel(address: flow.remoteAddress)
                if flow.remoteHostname != nil, let address = flow.remoteAddress {
                    Text(address.description)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                } else if flow.remoteHostname == nil {
                    Text("Hostname unknown")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help("The app connected by address, or resolved the name with encrypted DNS Squealer can't see.")
                }
            }
        }
    }

    private var scopeControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Server").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    ScopeSelector(selection: remoteBinding, options: serverOptions)
                }
                if flow.direction == .outbound {
                    GridRow {
                        Text("Port").foregroundStyle(.secondary)
                        ScopeSelector(selection: portBinding, options: [
                            (.this, "\(flow.remotePort)"),
                            (.any, String(localized: "Any port")),
                        ])
                    }
                }
                GridRow {
                    Text("Duration").foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ScopeSelector(selection: durationBinding, options: [
                            (.once, String(localized: "Once")),
                            (.untilQuit, String(localized: "Until Quit")),
                            (.forever, String(localized: "Forever")),
                        ] + (Self.mainDurations.contains(duration) ? [] : [(duration, Self.title(for: duration))]))
                        Menu {
                            ForEach(AlertScope.Duration.allCases.filter { !Self.mainDurations.contains($0) }, id: \.self) { option in
                                Button(Self.title(for: option)) { durationChoice = option }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("More durations")
                        .accessibilityLabel("More durations")
                    }
                }
            }
            .font(.callout)

            if isBrowser && flow.direction == .outbound {
                Label("Browsers connect to every site you visit, so allowing any server is usually what you want.", systemImage: "globe")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: duration == .once ? "hand.tap" : "list.bullet.rectangle")
                    .foregroundStyle(.secondary)
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let profile = model.activeProfile, duration != .once {
                    Toggle(isOn: $saveToProfile) {
                        Label(profile.name, systemImage: profile.symbol)
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Save the rule only in the \(profile.name) profile")
                }
            }
        }
    }

    private var details: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            KeyValueRow(key: "Path", value: flow.process.path, monospaced: true)
            if let id = flow.process.signingID { KeyValueRow(key: "Identifier", value: id, monospaced: true) }
            if let team = flow.process.teamID { KeyValueRow(key: "Team", value: team, monospaced: true) }
            if let cdhash = flow.process.cdhash { KeyValueRow(key: "CDHash", value: String(cdhash.prefix(20)) + "…", monospaced: true) }
            KeyValueRow(key: "PID", value: "\(flow.instance.pid)")
            if let via = flow.via { KeyValueRow(key: "Via", value: via.path, monospaced: true) }
            if let address = flow.remoteAddress { KeyValueRow(key: "Address", value: address.description, monospaced: true) }
            KeyValueRow(key: "Protocol", value: "\(flow.transport.rawValue.uppercased()), local port \(flow.localPort)")
        }
        .font(.caption)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.snappy) { showDetails.toggle() }
            } label: {
                Image(systemName: "info.circle")
            }
            .accessibilityLabel(showDetails ? "Hide details" : "Show details")
            .buttonStyle(.borderless)
            .help(showDetails ? "Hide details" : "Show details")
            .keyboardShortcut("i", modifiers: .command)

            Button("Decide Later") {
                guard isArmed else { return }
                model.resolve(alert, outcome: .later)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help("Let it through for now and add it to the review list")

            Spacer()

            Button("Deny") { decide(.deny) }
                .keyboardShortcut(.delete, modifiers: .command)
                .buttonStyle(DecisionButtonStyle(color: Theme.deny, prominent: false))
                .help("Deny (⌘⌫)")

            Button("Allow") { decide(.allow) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(DecisionButtonStyle(color: Theme.allow, prominent: true))
                .help("Allow (Return)")
        }
    }

    private var scope: AlertScope {
        AlertScope(remote: effectiveRemoteScope, ports: portScope, duration: duration)
    }

    /// The domain option is meaningless without a hostname or when it would equal the host.
    private var effectiveRemoteScope: AlertScope.Remote {
        remoteScope == .domain && domainLabel == nil ? .host : remoteScope
    }

    private static let mainDurations: Set<AlertScope.Duration> = [.once, .untilQuit, .forever]

    static func title(for duration: AlertScope.Duration) -> String {
        switch duration {
        case .once: String(localized: "Once")
        case .minute: String(localized: "1 Minute")
        case .untilQuit: String(localized: "Until Quit")
        case .hour: String(localized: "1 Hour")
        case .untilRestart: String(localized: "Until Restart")
        case .untilLogout: String(localized: "Until Logout")
        case .forever: String(localized: "Forever")
        }
    }

    private var serverOptions: [(AlertScope.Remote, String)] {
        var options: [(AlertScope.Remote, String)] = [(.host, hostLabel)]
        if let domain = domainLabel {
            options.append((.domain, domain))
        }
        options.append((.any, String(localized: "Any server")))
        return options
    }

    private var hostLabel: String {
        flow.remoteDisplayName
    }

    private var domainLabel: String? {
        if flow.remoteAddress?.isLocal == true { return String(localized: "Local network") }
        guard let hostname = flow.remoteHostname else { return nil }
        let domain = DomainName.registrableDomain(of: hostname)
        return domain == hostname ? nil : "*.\(domain)"
    }

    private var preview: String {
        guard let rule = RuleBuilder.rule(for: flow, action: .allow, scope: scope, session: Session.current) else {
            return String(localized: "Just these connections. You'll be asked again next time.")
        }
        let remote = RuleText.remote(rule.remote)
        let ports = rule.ports == .any ? String(localized: "any port") : String(localized: "port \(flow.remotePort)")
        let lifetime = switch duration {
        case .untilQuit: String(localized: "until \(ProcessPresentation.name(for: flow.process)) quits")
        case .hour: String(localized: "for the next hour")
        case .minute: String(localized: "for the next minute")
        case .untilRestart: String(localized: "until the Mac restarts")
        case .untilLogout: String(localized: "until you log out")
        default: String(localized: "from now on")
        }
        return String(localized: "Remembers this for \(remote) on \(ports), \(lifetime).")
    }

    private func decide(_ action: RuleAction) {
        guard isArmed else { return }
        let profileID = saveToProfile ? model.activeProfile?.id : nil
        if let rule = RuleBuilder.rule(for: flow, action: action, scope: scope, profileID: profileID, session: Session.current) {
            model.resolve(alert, outcome: .rule(rule))
        } else {
            model.resolve(alert, outcome: .once(action))
        }
    }
}

/// Stays colored when the panel isn't key, unlike the system prominent style, so the alert never looks disabled.
private struct DecisionButtonStyle: ButtonStyle {
    var color: Color
    var prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(minWidth: 76)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(prominent ? Color.white : color)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(prominent ? AnyShapeStyle(color.gradient) : AnyShapeStyle(color.opacity(0.16)))
                    .overlay {
                        if !prominent {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(color.opacity(0.45))
                        }
                    }
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

/// A segmented control that truncates long labels (host names) instead of growing past the panel's width.
private struct ScopeSelector<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [(Value, String)]
    @Namespace private var namespace

    var body: some View {
        ProportionalRow(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                let selected = value == selection
                Button {
                    withAnimation(.snappy(duration: 0.18)) { selection = value }
                } label: {
                    Text(label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color(nsColor: .controlColor))
                                    .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(label)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A material that keeps its active appearance; SwiftUI materials fade to grey whenever the panel isn't key,
/// which is most of the time for a non-activating alert.
private struct ActiveMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Lays segments out side by side, giving each width in proportion to what its label needs, so a long label
/// only truncates when the row genuinely can't fit everything (equal widths truncate long labels even when
/// short neighbours have room to spare).
private struct ProportionalRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let idealWidth = ideal.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, subviews.count - 1))
        return CGSize(width: proposal.width ?? idealWidth, height: ideal.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let available = max(0, bounds.width - spacing * CGFloat(max(0, subviews.count - 1)))
        // No segment may claim most of the row, so one long host name truncates instead of squeezing its neighbours.
        let cap = available * (subviews.count <= 2 ? 0.6 : 0.45)
        let ideal = subviews.map { min($0.sizeThatFits(.unspecified).width, cap) }
        let total = ideal.reduce(0, +)
        let widths: [CGFloat] = total <= available
            ? ideal.map { $0 + (available - total) / CGFloat(max(1, subviews.count)) }
            : ideal.map { total > 0 ? $0 * available / total : 0 }
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}
