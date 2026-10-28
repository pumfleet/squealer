import AppKit

enum Links {
    static let repository = URL(string: "https://github.com/pumfleet/squealer")!
    static let newIssue = URL(string: "https://github.com/pumfleet/squealer/issues/new")!
}

enum AboutPanel {
    @MainActor
    static func show() {
        let markdown = String(localized: "Free software under the GNU General Public License v3.\n[Source code and issues on GitHub](\(Links.repository.absoluteString))\n\nIP geolocation by [DB-IP.com](https://db-ip.com), CC BY 4.0.")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let credits = NSMutableAttributedString((try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let range = NSRange(location: 0, length: credits.length)
        credits.addAttributes([
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ], range: range)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }
}
