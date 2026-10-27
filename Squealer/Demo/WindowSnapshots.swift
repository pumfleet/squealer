#if DEBUG
import AppKit
import SquealerKit
import SwiftUI

/// `-snapshot <directory>` writes every visible window to PNG, for checking layouts without screen-recording
/// permission.
@MainActor
enum WindowSnapshots {
    /// `-dump <directory>` periodically writes the model's state as JSON and snapshots every window.
    static func scheduleDumpIfRequested(model: AppModel) {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-dump"), arguments.indices.contains(index + 1) else { return }
        let directory = URL(fileURLWithPath: arguments[index + 1])
        let requestedMode = arguments.firstIndex(of: "-mode").flatMap { arguments.indices.contains($0 + 1) ? FilterMode(rawValue: arguments[$0 + 1]) : nil }
        Task {
            while !Task.isCancelled {
                if let requestedMode, model.connection.isConnected, model.settings.mode != requestedMode {
                    model.setMode(requestedMode)
                }
                try? await Task.sleep(for: .seconds(3))
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let state: [String: Any] = [
                    "connection": "\(model.connection)",
                    "settings": "\(model.settings)",
                    "rules": model.rules.map { model.describe($0) },
                    "alerts": model.alerts.map { "\($0.flow.process.displayName) → \($0.flow.remoteDisplayName):\($0.flow.remotePort) ×\($0.attempts)" },
                    "review": model.review.map { "\($0.flow.process.displayName) → \($0.flow.remoteDisplayName) \($0.action) \($0.reason)" },
                    "rate": [model.currentRate.bytesIn, model.currentRate.bytesOut],
                    "connections": model.connections.values.sorted { $0.lastSeen > $1.lastSeen }.prefix(2000).map {
                        "\($0.process.displayName)\($0.via.map { " via \($0.displayName)" } ?? "") → \($0.endpoint.host):\($0.endpoint.port)/\($0.endpoint.transport) [\($0.hostnameSource)] \($0.lastVerdict.action)/\($0.lastVerdict.kind) in=\($0.bytesIn) out=\($0.bytesOut) active=\($0.activeFlows) total=\($0.totalFlows) denied=\($0.deniedFlows) signer=\($0.process.signer)"
                    },
                ]
                if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: directory.appendingPathComponent("state.json"))
                }
                capture(to: directory, suffix: "live")
            }
        }
    }

    /// `-tour <directory>` walks every main-window section (and the menu bar popover) and snapshots each.
    static func scheduleTourIfRequested(model: AppModel, extensionManager: ExtensionManager) {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-tour"), arguments.indices.contains(index + 1) else { return }
        let directory = URL(fileURLWithPath: arguments[index + 1])
        Task {
            try? await Task.sleep(for: .seconds(4))
            let sections: [(MainSection, String)] = [
                (.connections, "connections"), (.active, "active"), (.blocked, "blocked"), (.review, "review"),
                (.map, "map"), (.rules, "rules"), (.blocklists, "blocklists"), (.profiles, "profiles"),
            ]
            for (section, name) in sections {
                NavigationModel.shared.section = section
                try? await Task.sleep(for: .seconds(3))
                if let window = NSApp.windows.filter({ $0.isVisible && !($0 is NSPanel) }).max(by: { $0.frame.width < $1.frame.width }) {
                    write(window, to: directory.appendingPathComponent("section-\(name).png"))
                }
            }
            if let window = NSApp.windows.filter({ $0.isVisible && !($0 is NSPanel) }).max(by: { $0.frame.width < $1.frame.width }),
               let root = window.contentView?.superview {
                var report: [String] = []
                @MainActor func walk(_ view: NSView) {
                    if let table = view as? NSTableView {
                        report.append("\(type(of: table)) rows=\(table.numberOfRows) frame=\(table.convert(table.bounds, to: nil))")
                        if let outline = table as? NSOutlineView, outline.numberOfRows > 0 {
                            write(view: outline, to: directory.appendingPathComponent("sidebar-outline.png"))
                        }
                    }
                    view.subviews.forEach(walk)
                }
                walk(root)
                try? report.joined(separator: "\n").write(to: directory.appendingPathComponent("tables.txt"), atomically: true, encoding: .utf8)
            }
            let popover = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
            let hosting = NSHostingView(rootView: MenuBarView().environment(model).environment(extensionManager))
            popover.contentView = hosting
            popover.setContentSize(hosting.fittingSize)
            popover.orderFront(nil)
            try? await Task.sleep(for: .seconds(2))
            write(popover, to: directory.appendingPathComponent("menubar.png"))
            popover.close()
        }
    }

    private static func write(view: NSView, to url: URL) {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func write(_ window: NSWindow, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let view = window.contentView?.superview ?? window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    static func scheduleIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-snapshot"), arguments.indices.contains(index + 1) else { return }
        let directory = URL(fileURLWithPath: arguments[index + 1])
        Task {
            for round in 1...3 {
                try? await Task.sleep(for: .seconds(4))
                capture(to: directory, suffix: "\(round)")
            }
        }
    }

    static func capture(to directory: URL, suffix: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (index, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let name = (window.title.isEmpty ? String(describing: type(of: window)) : window.title)
                .replacingOccurrences(of: " ", with: "-")
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("\(index)-\(name)-\(suffix).png"))
        }
    }
}
#endif
