import AppKit
import SwiftUI

/// A Grid stack, open over its icon: the folder's entries as large icons, subfolders browsed in
/// place. Owned by the `DockController` whose bar it hangs off — only that controller knows where
/// the icon is.
///
/// Nothing runs while it is up. It closes on events alone — a click anywhere outside it, Escape,
/// another app coming forward, a second click on its stack — through monitors and an observer that
/// exist only while it is open.
@MainActor
final class StackGridController {
    private let panel = DockPopupPanel(acceptsKey: true)
    private let host = FirstMouseHostingView(rootView: AnyView(EmptyView()))
    private var monitors: [Any] = []
    private var activationObserver: NSObjectProtocol?
    /// The dock item it was opened from, while it is up.
    private(set) var itemID: String?
    /// The stack's own folder first, then each subfolder browsed into.
    private var path: [URL] = []
    private var sort = StackSort.standard
    private var anchor: DockAnchor?
    private var visible: NSRect?

    /// Whether a mouse-down in one of DockPlus's own windows leaves the grid up. The owner answers yes
    /// for a left click on this grid's own stack icon: that click closes the grid itself, and closing
    /// on its mouse-down as well would have the click open it straight back.
    var keepsOpen: (NSEvent) -> Bool = { _ in false }
    /// Once per close, however it closed.
    var onClose: () -> Void = {}

    var isShown: Bool { itemID != nil }

    init() {
        panel.contentView = host
    }

    func contains(_ point: NSPoint) -> Bool {
        isShown && panel.frame.contains(point)
    }

    func show(_ itemID: String, folder: URL, sort: StackSort, at anchor: DockAnchor, within visible: NSRect?) {
        self.itemID = itemID
        self.sort = sort
        self.anchor = anchor
        self.visible = visible
        path = [folder]
        present()
        // Key, so Escape reaches it. Non-activating, so DockPlus does not come forward and the app in
        // front stays in front.
        panel.makeKeyAndOrderFront(nil)
        arm()
    }

    func close() {
        guard isShown else { return }
        itemID = nil
        path = []
        anchor = nil
        disarm()
        panel.orderOut(nil)
        // Thirty icons at full size; a closed grid keeps none of them.
        host.rootView = AnyView(EmptyView())
        onClose()
    }

    /// The folder at the end of `path`, read afresh: going back shows what is there now, not what
    /// was there on the way in. The panel is re-fitted to it and re-hung from the same anchor.
    private func present() {
        guard let folder = path.last, let anchor else { return }
        let (entries, isDenied) = StackMenu.read(folder, needsKind: sort == .kind)
        let shown = DockModel.stackContents(entries, sortedBy: sort, limit: DockModel.stackGridLimit)
        let parent = path.count > 1 ? path[path.count - 2] : nil
        host.rootView = AnyView(StackGridView(
            title: FileManager.default.displayName(atPath: folder.path),
            cells: shown.map { StackGridCell(entry: $0, icon: NSWorkspace.shared.icon(forFile: $0.url.path)) },
            isDenied: isDenied,
            backTitle: parent.map { FileManager.default.displayName(atPath: $0.path) },
            open: { [weak self] entry in self?.open(entry) },
            back: { [weak self] in self?.back() },
            openInFinder: { [weak self] in
                NSWorkspace.shared.open(folder)
                self?.close()
            },
            openPrivacySettings: { [weak self] in
                StackMenu.openPrivacySettings()
                self?.close()
            }
        ))
        panel.setFrame(anchor.frame(for: host.fittingSize, within: visible), display: true)
    }

    private func open(_ entry: StackEntry) {
        if entry.isFolder {
            path.append(entry.url)
            present()
        } else {
            NSWorkspace.shared.open(entry.url)
            close()
        }
    }

    private func back() {
        guard path.count > 1 else { return }
        path.removeLast()
        present()
    }

    private func arm() {
        guard monitors.isEmpty else { return }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // Other apps' windows, the desktop, the menu bar.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) {
            monitors.append(global)
        }
        // DockPlus's own windows, which a global monitor never sees: this dock, another display's, Settings.
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window !== self.panel, !self.keepsOpen(event) else { return }
                self.close()
            }
            return event
        }) {
            monitors.append(local)
        }
        // 53 is Escape. Swallowed, so it does not also beep.
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard event.keyCode == 53, let self else { return false }
                self.close()
                return true
            }
            return handled ? nil : event
        }) {
            monitors.append(keys)
        }
        // Command-Tab brings another app forward with no click to see; the grid would stay up, with
        // the keyboard gone to that app and Escape with it.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func disarm() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }

    /// Roughly square, as the macOS Dock's grid is — five by four for twenty, six by five for thirty —
    /// and never wider than six. Pure, for the tests.
    nonisolated static func columns(for count: Int) -> Int {
        min(max(Int(Double(count).squareRoot().rounded(.up)), 1), 6)
    }
}

private struct StackGridCell: Identifiable {
    let entry: StackEntry
    let icon: NSImage
    var id: URL { entry.url }
}

private struct StackGridView: View {
    let title: String
    let cells: [StackGridCell]
    let isDenied: Bool
    /// The folder Back returns to, while browsing below the stack's own.
    let backTitle: String?
    let open: (StackEntry) -> Void
    let back: () -> Void
    let openInFinder: () -> Void
    let openPrivacySettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let backTitle {
                    Button(action: back) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back to \(backTitle)")
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    // No ideal width of its own, so the grid sizes the panel and a long folder name
                    // truncates — its one-line width had pushed the panel off the screen (measured:
                    // 264 characters made it 1732pt wide, against the grid's 302).
                    .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
            }
            content
            Button("Open in Finder", action: openInFinder)
        }
        .frame(minWidth: 220, alignment: .leading)
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(4)
    }

    @ViewBuilder private var content: some View {
        if isDenied {
            VStack(alignment: .leading, spacing: 6) {
                Text("DockPlus can't read this folder")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button("Open Files and Folders Settings…", action: openPrivacySettings)
            }
        } else if cells.isEmpty {
            Text("No Items")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60)
        } else {
            // `Grid`, not `LazyVGrid`: eager, so the hosting view's fitting size is the whole grid,
            // and the panel is sized from that.
            let columns = StackGridController.columns(for: cells.count)
            let rows = stride(from: 0, to: cells.count, by: columns).map {
                Array(cells[$0..<min($0 + columns, cells.count)])
            }
            Grid(alignment: .top, horizontalSpacing: 4, verticalSpacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(row) { StackGridItem(cell: $0, open: open) }
                    }
                }
            }
        }
    }
}

private struct StackGridItem: View {
    let cell: StackGridCell
    let open: (StackEntry) -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            open(cell.entry)
        } label: {
            VStack(spacing: 4) {
                Image(nsImage: cell.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 56, height: 56)
                // Two lines, as Finder's icon view wraps a name, then cut in the middle so the
                // extension stays in sight.
                Text(cell.entry.name)
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(width: 80, height: 28, alignment: .top)
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(isHovered ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(cell.entry.name)
        .accessibilityValue(cell.entry.isFolder ? "folder" : "")
    }
}
