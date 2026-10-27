import Charts
import SquealerKit
import SwiftUI

struct AppIcon: View {
    var process: ProcessIdentity?
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let process {
                Image(nsImage: ProcessPresentation.icon(for: process))
                    .resizable()
            } else {
                Image(systemName: "square.stack.3d.up.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.15)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct ProcessLabel: View {
    var process: ProcessIdentity
    var via: ProcessIdentity?
    var iconSize: CGFloat = 20

    var body: some View {
        HStack(spacing: 8) {
            AppIcon(process: process, size: iconSize)
            VStack(alignment: .leading, spacing: 1) {
                Text(ProcessPresentation.name(for: process))
                    .lineLimit(1)
                if let via {
                    Text("via \(ProcessPresentation.name(for: via))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

struct SignerBadge: View {
    var process: ProcessIdentity

    var body: some View {
        let (symbol, color): (String, Color) = switch process.signer {
        case .apple: ("apple.logo", .secondary)
        case .appStore: ("bag.fill", .blue)
        case .developerID: ("checkmark.seal.fill", .teal)
        case .adHoc: ("exclamationmark.triangle.fill", Theme.pending)
        case .unsigned, .invalid: ("exclamationmark.octagon.fill", Theme.deny)
        }
        Label(ProcessPresentation.signerDescription(process), systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
            .help(process.signingID ?? process.path)
    }
}

struct Pill: View {
    var text: LocalizedStringKey
    var symbol: String?
    var color: Color

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).imageScale(.small)
            }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .foregroundStyle(color)
        .background(color.opacity(0.14), in: Capsule())
    }
}

struct VerdictChip: View {
    var verdict: VerdictInfo
    var compact = false

    var body: some View {
        Pill(text: title, symbol: symbol, color: color)
            .help(help)
    }

    private var color: Color {
        if verdict.kind == .pending { return Theme.pending }
        return Theme.color(for: verdict.action)
    }

    private var symbol: String {
        switch verdict.kind {
        case .pending: "hourglass"
        case .builtin: verdict.builtin == .applePlatform ? "apple.logo" : "gearshape.fill"
        case .silent, .noClient, .timeout: "moon.fill"
        default: Theme.symbol(for: verdict.action)
        }
    }

    private var title: LocalizedStringKey {
        if verdict.kind == .pending { return "Waiting" }
        if compact { return verdict.action == .allow ? "Allowed" : "Denied" }
        switch verdict.kind {
        case .rule: return verdict.action == .allow ? "Allowed" : "Denied"
        case .builtin: return "System"
        case .silent: return verdict.action == .allow ? "Silently allowed" : "Silently denied"
        case .noClient: return verdict.action == .allow ? "Allowed (no app)" : "Denied (no app)"
        case .timeout: return "Timed out"
        case .once: return verdict.action == .allow ? "Allowed once" : "Denied once"
        case .pending: return "Waiting"
        }
    }

    private var help: String {
        switch verdict.kind {
        case .rule: String(localized: "Decided by a rule")
        case .builtin:
            switch verdict.builtin {
            case .applePlatform: String(localized: "Apple system software is allowed by default")
            case .appStore: String(localized: "App Store apps are allowed by default")
            case .systemService: String(localized: "Essential network services (DNS, DHCP, time) are always allowed")
            case .squealer: String(localized: "Squealer's own connections")
            case .appleServices: String(localized: "Apple and iCloud servers are allowed for every app")
            case .localDiscovery: String(localized: "Local network discovery (Bonjour, AirPlay, casting) is allowed")
            case .localIncoming: String(localized: "Incoming connections from the local network are allowed")
            case .systemExtension: String(localized: "System extensions you approved in System Settings are allowed")
            case .unsolicitedInbound: String(localized: "Unrequested incoming UDP traffic is blocked without asking")
            default: String(localized: "Built-in")
            }
        case .silent: String(localized: "Decided by silent mode")
        case .noClient: String(localized: "Decided while Squealer wasn't running")
        case .timeout: String(localized: "Nobody answered the alert in time")
        case .once: String(localized: "Decided once, from an alert")
        case .pending: String(localized: "Waiting for your decision")
        }
    }
}

/// Two-tone bar for download (in) and upload (out) relative to a shared maximum.
struct RateBar: View {
    var bytesIn: Double
    var bytesOut: Double
    var maximum: Double

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let scale = maximum > 0 ? width / maximum : 0
            HStack(spacing: 1) {
                Capsule().fill(Theme.inbound).frame(width: max(0, min(width, bytesIn * scale)))
                Capsule().fill(Theme.outbound).frame(width: max(0, min(width, bytesOut * scale)))
                Spacer(minLength: 0)
            }
            .animation(.smooth(duration: 0.6), value: bytesIn)
            .animation(.smooth(duration: 0.6), value: bytesOut)
        }
        .frame(height: 5)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .accessibilityLabel("Download \(Format.rate(bytesIn)), upload \(Format.rate(bytesOut))")
    }
}

struct RateLegend: View {
    var bytesIn: Double
    var bytesOut: Double

    var body: some View {
        HStack(spacing: 10) {
            Label(Format.rate(bytesIn), systemImage: "arrow.down")
                .foregroundStyle(Theme.inbound)
            Label(Format.rate(bytesOut), systemImage: "arrow.up")
                .foregroundStyle(Theme.outbound)
        }
        .font(.caption.monospacedDigit().weight(.medium))
        .labelStyle(.titleAndIcon)
    }
}

struct TrafficSparkline: View {
    var samples: [AppModel.RateSample]

    var body: some View {
        Chart {
            ForEach(samples) { sample in
                AreaMark(x: .value("Time", sample.date), y: .value("Download", sample.bytesIn), series: .value("Direction", "in"))
                    .foregroundStyle(Theme.inbound.opacity(0.35).gradient)
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", sample.date), y: .value("Download", sample.bytesIn), series: .value("Direction", "in"))
                    .foregroundStyle(Theme.inbound)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", sample.date), y: .value("Upload", -sample.bytesOut), series: .value("Direction", "out"))
                    .foregroundStyle(Theme.outbound)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
                AreaMark(x: .value("Time", sample.date), y: .value("Upload", -sample.bytesOut), series: .value("Direction", "out"))
                    .foregroundStyle(Theme.outbound.opacity(0.3).gradient)
                    .interpolationMethod(.monotone)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .accessibilityLabel("Network activity over the last minute and a half")
    }
}

struct GeoLabel: View {
    var address: IPAddress?
    var showOrganization = true

    var body: some View {
        if let location = GeoService.shared.location(for: address) {
            HStack(spacing: 4) {
                if let flag = location.flag {
                    Text(flag)
                }
                Text([location.placeName, showOrganization ? location.organization : nil].compactMap { $0 }.joined(separator: " · "))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct EmptyStateView: View {
    var title: LocalizedStringKey
    var symbol: String
    var message: LocalizedStringKey

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        }
    }
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(.background.secondary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }
}

extension View {
    func card() -> some View {
        modifier(CardBackground())
    }
}

struct KeyValueRow: View {
    var key: LocalizedStringKey
    var value: String
    var monospaced = false

    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(key)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ServiceBadge: View {
    var service: KnowledgeBase.Service

    var body: some View {
        Pill(text: "\(service.name) · \(service.category.title)", symbol: service.category.symbol, color: service.category.isTracking ? Theme.pending : .secondary)
            .lineLimit(1)
            .fixedSize()
            .help(service.category.isTracking ? "Collects data about how you use the app" : "")
    }
}

extension KnowledgeBase.Category {
    var title: String {
        switch self {
        case .analytics: String(localized: "Analytics")
        case .advertising: String(localized: "Advertising")
        case .crashReporting: String(localized: "Crash reporting")
        case .logging: String(localized: "Logging & monitoring")
        case .featureFlags: String(localized: "Feature flags")
        case .cdn: String(localized: "Content delivery")
        case .cloud: String(localized: "Cloud services")
        case .payments: String(localized: "Payments")
        case .authentication: String(localized: "Sign-in & verification")
        case .updates: String(localized: "Updates")
        case .messaging: String(localized: "Communication")
        case .collaboration: String(localized: "Productivity")
        case .ai: String(localized: "AI service")
        case .maps: String(localized: "Maps")
        case .media: String(localized: "Media")
        case .developer: String(localized: "Developer service")
        case .security: String(localized: "Security")
        case .platform: String(localized: "Platform service")
        }
    }

    var symbol: String {
        switch self {
        case .analytics: "chart.bar.xaxis"
        case .advertising: "megaphone"
        case .crashReporting: "ant"
        case .logging: "list.bullet.clipboard"
        case .featureFlags: "flag"
        case .cdn: "shippingbox"
        case .cloud: "cloud"
        case .payments: "creditcard"
        case .authentication: "person.badge.key"
        case .updates: "arrow.down.circle"
        case .messaging: "bubble.left.and.bubble.right"
        case .collaboration: "doc.richtext"
        case .ai: "sparkles"
        case .maps: "map"
        case .media: "play.rectangle"
        case .developer: "hammer"
        case .security: "lock.shield"
        case .platform: "building.columns"
        }
    }
}
