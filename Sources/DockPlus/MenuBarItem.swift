import AppKit

/// DockPlus's menu bar icon, present while the "Show menu bar icon" setting is on. Hiding it loses
/// nothing: Settings and Quit are also on the dock's own right-click menu, and updates are in
/// Settings ▸ About.
@MainActor
final class MenuBarItem: NSObject, NSMenuDelegate {
    private let settings: DockSettings
    private var item: NSStatusItem?

    init(settings: DockSettings) {
        self.settings = settings
        super.init()
        update()
    }

    private func update() {
        // Re-running the read is the whole update, so there is nothing more to do on a change.
        observeContinuously(ownedBy: self) { [weak self] in
            guard let self else { return }
            settings.showsMenuBarIcon ? install() : remove()
        } onChange: {}
    }

    private func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.icon()
        let menu = NSMenu()
        // Filled in as it opens, so it costs nothing until then and is never stale.
        menu.delegate = self
        item.menu = menu
        self.item = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(ClosureMenuItem("DockPlus Settings…") { SettingsWindow.show() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Quit DockPlus") { NSApp.terminate(nil) })
    }

    /// A screen with its dock along the bottom edge, the middle tile magnified. Drawn rather than
    /// bundled because build.sh copies only the .icns into Resources, and a template image lets the
    /// system tint it for light, dark and highlighted menu bars.
    private static func icon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            let screen = NSBezierPath(
                roundedRect: NSRect(x: 1, y: 2, width: 16, height: 14), xRadius: 3, yRadius: 3)
            screen.lineWidth = 1.5
            screen.stroke()
            let tiles = [
                NSRect(x: 4.2, y: 4.2, width: 2.6, height: 2.6),
                NSRect(x: 7.4, y: 4.2, width: 3.2, height: 4.2),
                NSRect(x: 11.2, y: 4.2, width: 2.6, height: 2.6),
            ]
            for tile in tiles {
                NSBezierPath(roundedRect: tile, xRadius: 0.8, yRadius: 0.8).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "DockPlus"
        return image
    }

    private func remove() {
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }
}
