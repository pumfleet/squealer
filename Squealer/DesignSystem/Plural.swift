import Foundation

/// Counted phrases ("1 connection" / "3 connections"), each a complete localizable string so translators see
/// the noun, using Foundation's grammar agreement.
enum Plural {
    static func connections(_ count: Int) -> String {
        String(AttributedString(localized: "^[\(count) connection](inflect: true)").characters)
    }

    static func appsAndServers(_ apps: Int, _ servers: Int) -> String {
        String(AttributedString(localized: "^[\(apps) app](inflect: true) · ^[\(servers) server](inflect: true)").characters)
    }
}
