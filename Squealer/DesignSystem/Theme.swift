import SquealerKit
import SwiftUI

enum Theme {
    static let brand = Color("Brand")
    static let allow = Color(red: 0.20, green: 0.70, blue: 0.42)
    static let deny = Color(red: 0.92, green: 0.30, blue: 0.29)
    static let pending = Color(red: 0.96, green: 0.62, blue: 0.16)
    static let inbound = Color(red: 0.25, green: 0.56, blue: 0.96)
    static let outbound = Color(red: 0.62, green: 0.40, blue: 0.95)

    static func color(for action: RuleAction) -> Color {
        action == .allow ? allow : deny
    }

    static func symbol(for action: RuleAction) -> String {
        action == .allow ? "checkmark.circle.fill" : "xmark.octagon.fill"
    }

    static func symbol(for mode: FilterMode) -> String {
        switch mode {
        case .alert: "shield.lefthalf.filled"
        case .silentAllow: "shield.lefthalf.filled.badge.checkmark"
        case .silentDeny: "shield.lefthalf.filled.slash"
        case .off: "shield.slash"
        }
    }

    static func title(for mode: FilterMode) -> LocalizedStringKey {
        switch mode {
        case .alert: "Ask"
        case .silentAllow: "Allow"
        case .silentDeny: "Deny"
        case .off: "Off"
        }
    }

    static func summary(for mode: FilterMode) -> LocalizedStringKey {
        switch mode {
        case .alert: "Ask about new connections"
        case .silentAllow: "Silently allow new connections"
        case .silentDeny: "Silently deny new connections"
        case .off: "Filtering is off"
        }
    }
}

enum Format {
    nonisolated(unsafe) private static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    static func bytes(_ count: UInt64) -> String {
        bytes.string(fromByteCount: Int64(clamping: count))
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond >= 1 else { return "—" }
        return bytes.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }

    static func compactRate(_ bytesPerSecond: Double) -> String {
        let units = ["B", "K", "M", "G"]
        var value = bytesPerSecond
        var unit = 0
        while value >= 1_000, unit < units.count - 1 {
            value /= 1_024
            unit += 1
        }
        return value < 10 && unit > 0 ? String(format: "%.1f%@", value, units[unit]) : String(format: "%.0f%@", value, units[unit])
    }

    static func relative(_ date: Date, now: Date = .now) -> String {
        if now.timeIntervalSince(date) < 5 { return String(localized: "now") }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    static func port(_ port: UInt16, transport: TransportProtocol) -> String {
        let service = Ports.serviceName(for: port).map { " · \($0)" } ?? ""
        let proto = transport == .any ? "" : " \(transport.rawValue.uppercased())"
        return "\(port)\(service)\(proto)"
    }
}
