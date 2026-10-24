// The robot on the desktop, as Buddy will show it: a borderless, transparent
// panel above other windows on every Space, that never takes focus. Clicks
// pass through it everywhere but the robot's silhouette; a click on the robot
// pokes it, and holding the button down drags the panel by the robot.

import AppKit
import CharacterKit

@MainActor
final class FloatingPanelController {
    /// The robot's resting box in the panel, in points.
    var box: CGFloat = 220
    /// Called when the panel closes.
    var onClose: (() -> Void)?

    private var panel: NSPanel?
    private(set) var view: CharacterView?

    var isOpen: Bool { panel != nil }

    /// Show `character` in the panel, replacing whatever it showed, and return the view drawing it.
    @discardableResult
    func show(_ character: any CharacterRenderer) -> CharacterView {
        let size = CharacterView.canvasSize(for: character, box: box)
        let panel = self.panel ?? makePanel(size: size)
        let view = CharacterView(character: character)
        view.preferredBox = box
        view.frame = NSRect(origin: .zero, size: size)
        view.autoresizingMask = [.width, .height]
        // the click has already poked the robot; a drag that follows moves the panel
        view.onClick = { [weak panel] event in panel?.performDrag(with: event) }
        panel.contentView = view
        view.managesWindowClickThrough = true
        self.panel = panel
        self.view = view
        panel.orderFrontRegardless()
        return view
    }

    func close() {
        guard let panel else { return }
        view?.managesWindowClickThrough = false
        panel.contentView = nil
        panel.orderOut(nil)
        self.panel = nil
        view = nil
        onClose?()
    }

    private func makePanel(size: CGSize) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        // bottom right of the main screen, clear of the Dock
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 40, y: screen.minY + 40))
        }
        return panel
    }
}
