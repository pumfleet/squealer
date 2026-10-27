import AppKit
import SwiftUI

/// Shows connection alerts in a floating panel that doesn't activate Squealer, so it never steals focus from
/// what the user is typing; clicking it makes it key so keyboard shortcuts work.
@MainActor
final class AlertPanelController {
    private let model: AppModel
    private var panel: AlertPanel?
    private var lastCount = 0

    init(model: AppModel) {
        self.model = model
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = model.alerts.count
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
    }

    private func update() {
        let count = model.alerts.count
        defer { lastCount = count }
        guard count > 0 else {
            panel?.orderOut(nil)
            return
        }
        let panel = panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible {
            position(panel)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = 1
            }
        }
        if count > lastCount, UserDefaults.standard.object(forKey: "alert.sound") as? Bool ?? true {
            NSSound(named: "Tink")?.play()
        }
    }

    /// The panel is sized by hand from the content's measured height rather than letting the hosting view drive
    /// the window size: when the two disagree, AppKit and SwiftUI resize each other until the stack overflows.
    private func makePanel() -> AlertPanel {
        let content = AlertStackView()
            .environment(model)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak self] height in
                DispatchQueue.main.async { self?.resize(toHeight: height) }
            }
            .frame(width: AlertPanel.width, alignment: .top)
            .frame(maxHeight: .infinity, alignment: .top)
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        let panel = AlertPanel()
        panel.contentView = hosting
        panel.setContentSize(NSSize(width: AlertPanel.width, height: 360))
        return panel
    }

    private func resize(toHeight height: CGFloat) {
        guard let panel, height > 0, abs(panel.frame.height - height) > 0.5 else { return }
        var frame = panel.frame
        frame.size = NSSize(width: AlertPanel.width, height: height)
        panel.setFrame(frame, display: true)
    }

    /// Pins the panel's top-right corner just below the menu bar on the screen the pointer is on.
    private func position(_ panel: AlertPanel) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.anchor = NSPoint(x: visible.maxX - 14, y: visible.maxY - 10)
        panel.setFrame(panel.frame, display: false)
    }
}

final class AlertPanel: NSPanel {
    static let width: CGFloat = 440

    /// The top-right corner the panel stays attached to while its content grows and shrinks.
    var anchor: NSPoint?

    init() {
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .utilityWindow
        setAccessibilityLabel(String(localized: "Connection alert"))
        NotificationCenter.default.addObserver(self, selector: #selector(didMove), name: NSWindow.didMoveNotification, object: self)
    }

    override var canBecomeKey: Bool { true }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var frame = frameRect
        if let anchor {
            frame.origin = NSPoint(x: anchor.x - frame.width, y: anchor.y - frame.height)
        }
        if let visible = (screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        }
        super.setFrame(frame, display: flag)
    }

    /// Dragging the panel elsewhere makes that its new home for later resizes.
    @objc private func didMove(_ notification: Notification) {
        anchor = NSPoint(x: frame.maxX, y: frame.maxY)
    }
}
