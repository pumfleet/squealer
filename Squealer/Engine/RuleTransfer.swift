import Foundation
import SquealerKit

/// Exports rules as Squealer JSON or Little Snitch `.lsrules`, and imports either. Imported rules start out
/// unapproved so the user can check what came in.
enum RuleTransfer {
    struct Document: Codable {
        var format = "squealer-rules"
        var version = 1
        var exported = Date()
        var rules: [Rule]
    }

    struct ImportResult {
        var name: String?
        var rules: [Rule]
        var skipped: [String]
    }

    enum TransferError: LocalizedError {
        case unrecognized

        var errorDescription: String? {
            String(localized: "This file isn't a Squealer or Little Snitch rules file.")
        }
    }

    static func export(_ rules: [Rule]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Document(rules: rules.filter { $0.origin != .blocklist && $0.lifetime == .forever }))
    }

    static func importRules(from data: Data, groupID: UUID? = nil) throws -> ImportResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let document = try? decoder.decode(Document.self, from: data), document.format == "squealer-rules" {
            let rules = document.rules.map { rule in
                var rule = rule
                rule.id = UUID()
                rule.origin = .imported
                rule.isApproved = false
                rule.groupID = groupID
                return rule
            }
            return ImportResult(name: nil, rules: rules, skipped: [])
        }
        if LittleSnitchFormat.isLittleSnitchFile(data) {
            let result = try LittleSnitchFormat.parse(data, origin: .imported, groupID: groupID) { path in
                CodeSignature.identity(forPath: path, thorough: false)
            }
            return ImportResult(name: result.name, rules: result.rules, skipped: result.skipped)
        }
        throw TransferError.unrecognized
    }

    static func parsePorts(_ text: String?) -> PortMatcher {
        LittleSnitchFormat.parsePorts(text)
    }

    static func formatPorts(_ ports: PortMatcher) -> String {
        LittleSnitchFormat.formatPorts(ports)
    }
}
