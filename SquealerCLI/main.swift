import Foundation
import SquealerKit

/// `squealer`: inspect and control Squealer from Terminal. Reading works for anyone; changes require sudo,
/// which the extension enforces.
struct CLI {
    enum Failure: Error, CustomStringConvertible {
        case usage(String)
        case engine(String)

        var description: String {
            switch self {
            case .usage(let message), .engine(let message): message
            }
        }
    }

    static let usage = """
    Usage: squealer <command> [options]

      status                         Mode, profile and what's active right now
      mode [ask|allow|deny|off]      Show or change what happens to unknown connections (sudo)
      profile [name|default]         Show or switch the active profile (sudo)
      rules [--json]                 List rules
      connections [--json]           Connections in the last 24 hours, busiest first
      log [--since 1h] [--app NAME] [--denied] [--json]
                                     Recent connections from the log
      blocklists [update]            List blocklists, or update them now (sudo)
      backup                         Back up the configuration now (sudo)
      export                         Print the configuration as JSON
      import FILE                    Replace the configuration from a backup (sudo)
    """

    let arguments: [String]
    let connection: NSXPCConnection

    /// The tool lives in Squealer.app/Contents/Helpers (usually reached through a symlink), so it talks to the
    /// extension bundled with that same app.
    static var serviceName: String? {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return XPCConstants.machServiceName(ofExtensionAt: XPCConstants.bundledExtension(inApp: app))
            ?? XPCConstants.machServiceName(ofExtensionAt: XPCConstants.bundledExtension(inApp: URL(fileURLWithPath: "/Applications/Squealer.app")))
    }

    init(arguments: [String]) {
        self.arguments = arguments
        connection = NSXPCConnection(machServiceName: Self.serviceName ?? "", options: .privileged)
        connection.setCodeSigningRequirement(XPCConstants.codeSigningRequirement(for: XPCConstants.extensionBundleID))
        connection.remoteObjectInterface = NSXPCInterface(with: EngineXPCProtocol.self)
        connection.resume()
    }

    func send(_ request: EngineRequest) throws -> EngineResponse {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<EngineResponse, Error> = .failure(Failure.engine("No response"))
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            result = .failure(Failure.engine("Squealer's network extension isn't running."))
            semaphore.signal()
        } as? EngineXPCProtocol
        proxy?.handle(try XPCCoding.encode(request)) { data in
            if let response = try? XPCCoding.decode(EngineResponse.self, from: data) {
                if case .failure(let message) = response {
                    result = .failure(Failure.engine(message))
                } else {
                    result = .success(response)
                }
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 15) == .timedOut {
            throw Failure.engine("Timed out waiting for Squealer's network extension.")
        }
        return try result.get()
    }

    func snapshot() throws -> EngineSnapshot {
        guard case .snapshot(let snapshot) = try send(.hello(clientVersion: "cli")) else { throw Failure.engine("Unexpected response") }
        return snapshot
    }

    func option(_ name: String) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    var json: Bool { arguments.contains("--json") }

    func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    func run() throws {
        guard let command = arguments.first else { throw Failure.usage(Self.usage) }
        switch command {
        case "status":
            let snapshot = try snapshot()
            let profile = snapshot.settings.activeProfileID.flatMap { id in snapshot.profiles.first { $0.id == id }?.name } ?? "Default"
            let active = snapshot.connections.filter { $0.activeFlows > 0 }
            print("Engine        \(snapshot.engineVersion)")
            print("Mode          \(Self.modeName(snapshot.settings.mode))")
            print("Profile       \(profile)")
            print("Rules         \(snapshot.rules.count) (\(snapshot.ruleGroups.count) groups, \(snapshot.blocklists.filter(\.isEnabled).count) blocklists)")
            print("Active        \(Set(active.map(\.process.key)).count) apps, \(active.reduce(0) { $0 + $1.activeFlows }) connections")
            print("Waiting       \(snapshot.pendingAlerts.count) alerts, \(snapshot.review.count) to review")

        case "mode":
            guard arguments.count > 1 else {
                print(Self.modeName(try snapshot().settings.mode))
                return
            }
            let modes: [String: FilterMode] = ["ask": .alert, "alert": .alert, "allow": .silentAllow, "deny": .silentDeny, "off": .off]
            guard let mode = modes[arguments[1]] else { throw Failure.usage("Mode must be ask, allow, deny or off.") }
            var settings = try snapshot().settings
            settings.mode = mode
            _ = try send(.setSettings(settings))
            print("Mode is now \(Self.modeName(mode)).")

        case "profile":
            let snapshot = try snapshot()
            guard arguments.count > 1 else {
                print(snapshot.settings.activeProfileID.flatMap { id in snapshot.profiles.first { $0.id == id }?.name } ?? "Default")
                return
            }
            let name = arguments[1]
            var settings = snapshot.settings
            if name.lowercased() == "default" {
                settings.activeProfileID = nil
            } else {
                guard let profile = snapshot.profiles.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
                    throw Failure.usage("No profile named “\(name)”. Profiles: \(snapshot.profiles.map(\.name).joined(separator: ", "))")
                }
                settings.activeProfileID = profile.id
            }
            _ = try send(.setSettings(settings))
            print("Profile is now \(name).")

        case "rules":
            let snapshot = try snapshot()
            if json { return try printJSON(snapshot.rules) }
            let names = Dictionary(snapshot.blocklists.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            for rule in snapshot.rules.sorted(by: { ($0.processName ?? "", $0.createdAt) < ($1.processName ?? "", $1.createdAt) }) {
                let flags = [rule.isEnabled ? nil : "disabled", rule.isApproved ? nil : "unapproved"].compactMap { $0 }
                let suffix = flags.isEmpty ? "" : "  [\(flags.joined(separator: ", "))]"
                print("\(rule.action == .allow ? "✓" : "✗") \(RuleDescription.sentence(for: rule, blocklistNames: names))\(suffix)")
            }

        case "connections":
            let connections = try snapshot().connections.sorted { $0.bytesIn + $0.bytesOut > $1.bytesIn + $1.bytesOut }
            if json { return try printJSON(connections) }
            for summary in connections.prefix(50) {
                let data = Self.bytes(summary.bytesIn + summary.bytesOut)
                print("\(summary.lastVerdict.action == .allow ? "✓" : "✗") \(summary.process.displayName.padding(toLength: 24, withPad: " ", startingAt: 0)) \(summary.endpoint.host):\(summary.endpoint.port)  \(data)")
            }

        case "log":
            let since = Self.duration(option("--since") ?? "1h") ?? 3_600
            let snapshot = try snapshot()
            var process: ProcessKey?
            if let app = option("--app") {
                process = snapshot.connections.first { $0.process.displayName.localizedCaseInsensitiveContains(app) }?.process.key
                if process == nil { throw Failure.usage("No recent connections from an app matching “\(app)”.") }
            }
            guard case .log(let entries) = try send(.connectionLog(ConnectionLogQuery(since: .now - since, process: process, deniedOnly: arguments.contains("--denied"), limit: 1_000))) else { return }
            if json { return try printJSON(entries) }
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            for entry in entries.reversed() {
                let mark = entry.verdict.action == .allow ? "✓" : "✗"
                print("\(formatter.string(from: entry.start)) \(mark) \(entry.processName.padding(toLength: 22, withPad: " ", startingAt: 0)) \(entry.host):\(entry.port)  \(Self.bytes(entry.bytesIn + entry.bytesOut))")
            }

        case "blocklists":
            let snapshot = try snapshot()
            if arguments.dropFirst().first == "update" {
                for list in snapshot.blocklists {
                    _ = try send(.refreshBlocklist(list.id))
                    print("Updated \(list.name)")
                }
                return
            }
            for list in snapshot.blocklists {
                print("\(list.isEnabled ? "●" : "○") \(list.name)  \(list.entryCount) entries  \(list.url.absoluteString)")
            }

        case "backup":
            _ = try send(.createBackup)
            print("Backed up.")

        case "export":
            guard case .configuration(let backup) = try send(.exportConfiguration) else { return }
            try printJSON(backup)

        case "import":
            guard let path = arguments.dropFirst().first else { throw Failure.usage("Usage: squealer import FILE") }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let backup = try decoder.decode(ConfigurationBackup.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            _ = try send(.restoreConfiguration(backup))
            print("Imported \(backup.rules.count) rules. The previous configuration was backed up first.")

        case "help", "--help", "-h":
            print(Self.usage)

        default:
            throw Failure.usage(Self.usage)
        }
    }

    static func modeName(_ mode: FilterMode) -> String {
        switch mode {
        case .alert: "ask"
        case .silentAllow: "allow (silent)"
        case .silentDeny: "deny (silent)"
        case .off: "off"
        }
    }

    static func bytes(_ count: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(clamping: count))
    }

    /// "30m", "2h", "7d" or plain seconds.
    static func duration(_ text: String) -> TimeInterval? {
        let units: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3_600, "d": 86_400]
        if let unit = text.last, let multiplier = units[unit], let value = Double(text.dropLast()) {
            return value * multiplier
        }
        return Double(text)
    }
}

do {
    try CLI(arguments: Array(CommandLine.arguments.dropFirst())).run()
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
