import AppKit
import Foundation
import MetricKit

enum CommandLineTool {
    static let linkPath = "/usr/local/bin/squealer"

    static var bundledPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/squealer").path
    }

    static var isInstalled: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath)) == bundledPath
    }

    /// Links the bundled tool into /usr/local/bin, asking for an administrator password.
    static func install() -> String {
        if let error = runAsAdministrator("mkdir -p /usr/local/bin && ln -sf '\(bundledPath)' '\(linkPath)'") {
            return (error[NSAppleScript.errorMessage] as? String) ?? String(localized: "The tool couldn't be installed.")
        }
        return String(localized: "Installed. Try `squealer status` in Terminal.")
    }

    /// Removes the link if it points into a copy of Squealer, asking for an administrator password.
    static func uninstall() {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath),
              destination.hasSuffix("/Contents/Helpers/squealer") else { return }
        _ = runAsAdministrator("rm -f '\(linkPath)'")
    }

    private static func runAsAdministrator(_ command: String) -> NSDictionary? {
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(command)\" with administrator privileges")?.executeAndReturnError(&error)
        return error
    }
}

/// Collects crash and hang reports macOS delivers through MetricKit, so they can be attached to bug reports.
final class Diagnostics: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = Diagnostics()

    static var directory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Squealer/Diagnostics", isDirectory: true)
    }

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        for payload in payloads {
            let name = "diagnostic-\(Int(payload.timeStampEnd.timeIntervalSince1970)).json"
            try? payload.jsonRepresentation().write(to: Self.directory.appendingPathComponent(name))
        }
    }

    static func reveal() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }
}
