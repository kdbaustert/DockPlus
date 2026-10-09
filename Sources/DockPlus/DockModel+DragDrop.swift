import AppKit
import UniformTypeIdentifiers

/// The payload an icon carries while dragged inside the dock: the app's path under a type only DockPlus
/// knows. Not the app's file URL, which dropped on Finder would copy or alias the app, and not plain
/// text, which Finder drops on the desktop as a text clipping.
private let dragType = UTType(exportedAs: "dev.kennyb.dockplus.item")

/// An icon being dragged along the bar, as the macOS Dock does it: lifted out of its slot, with the
/// slot following the pointer as a gap the other icons slide apart for. `gap` is its index in the
/// bar as shown; nil while the pointer is off the bar, where the gap closes. `cancelled` marks a
/// drag Esc has ended: the icon is back in place, but the AppKit session runs until the button
/// comes up, and the release must find the drag to know to swallow it.
struct DockDrag: Equatable {
    let id: String
    var gap: Int?
    var cancelled = false
}

extension DockModel {
    static let dropTypes: [UTType] = [.fileURL, dragType]

    // MARK: - Dragging along the bar

    /// `items` with the dragged one moved to its gap, or taken out while it has none. Pure, for the
    /// tests.
    nonisolated static func arranged(_ items: [DockItem], drag: DockDrag?) -> [DockItem] {
        guard let drag, !drag.cancelled, let from = items.firstIndex(where: { $0.id == drag.id }) else { return items }
        var out = items
        let item = out.remove(at: from)
        guard let gap = drag.gap else { return out }
        out.insert(item, at: min(gap, out.count))
        return out
    }

    /// Where a dragged item's gap may go, as indexes into the bar without it — the places a drop can
    /// land it. An app or spacer goes anywhere among the apps before the separator, pinned or only
    /// running, Finder too; a widget among the widgets. Anything else has no gap: a stack, the
    /// Trash and a window do not reorder.
    nonisolated static func gapRange(for item: DockItem, in others: [DockItem]) -> ClosedRange<Int>? {
        switch item.kind {
        case .app, .spacer:
            return 0...(others.firstIndex { $0.kind == .separator } ?? others.count)
        case .nowPlaying, .weather, .clock, .battery, .calendar, .keepAwake:
            let widgets = others.indices.filter { others[$0].widgetName != nil }
            guard let first = widgets.first, let last = widgets.last else { return others.count...others.count }
            return first...(last + 1)
        case .folder, .trash, .separator, .minimizedWindow, .runningApps:
            return nil
        }
    }

    /// The gap for the pointer over the shown bar's item at `index` (nil: off the bar). Passing an
    /// icon moves the gap to its slot and the icon into the one the gap left; past the ends of where
    /// the item can go, the gap waits at the nearest end.
    nonisolated static func gap(for item: DockItem, over index: Int?, in shown: [DockItem]) -> Int? {
        guard let index else { return nil }
        let others = shown.filter { $0.id != item.id }
        guard let range = gapRange(for: item, in: others) else { return nil }
        return min(max(index, range.lowerBound), range.upperBound)
    }

    /// The icon lifted: its slot stays where it was, empty, until the pointer moves it.
    func beginDrag(_ item: DockItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }),
            Self.gapRange(for: item, in: items.filter { $0.id != item.id }) != nil
        else { return }
        drag = DockDrag(id: item.id, gap: index)
    }

    /// The pointer moved during a drag: over the bar's item at `index`, or off the bar (nil).
    /// `along` and `state` let the move be checked against the bar as it would look once moved: a
    /// new gap is taken only if the pointer would still sit on the dragged item's slot afterwards.
    /// Without that, a narrow item dragged over a wider one swapped with it every tick — the wider
    /// icon kept landing back under the pointer — and the icons jittered at display rate.
    func moveDrag(over index: Int?, along: CGFloat? = nil, state: PanelState? = nil) {
        guard let current = drag, !current.cancelled,
              let item = builtItems.first(where: { $0.id == current.id }) else { return }
        let gap = Self.gap(for: item, over: index, in: items)
        guard gap != current.gap else { return }
        // Only an exact slot-for-slot move is checked. A gap clamped to its range's end (gap !=
        // index) stays at that end wherever the pointer wanders, which cannot oscillate.
        if let gap, gap == index, let along, let state {
            let moved = Self.arranged(builtItems, drag: DockDrag(id: current.id, gap: gap))
            guard layout(of: moved, for: state).index(at: along) == gap else { return }
        }
        drag?.gap = gap
    }

    /// The drag ended off the bar or was cancelled: the icon goes back where it was.
    func endDrag() {
        drag = nil
    }

    /// Esc during a drag. Clearing the drag outright is not enough: the AppKit session is still
    /// live, and a release over the bar then read the payload and moved or pinned the item anyway.
    /// Marked cancelled instead, the icon goes back now and `handleDrop` swallows the release.
    func cancelDrag() {
        guard drag != nil, drag?.cancelled != true else { return }
        drag?.cancelled = true
    }

    /// The drag ended well away from the bar: the item comes off it, as a Dock icon dragged away
    /// does. False, with the drag left for `endDrag` to put back, for anything its menu could not
    /// remove either. A widget's switch is the one Settings and its menu turn off.
    func endDragRemoving() -> Bool {
        guard drag?.cancelled != true,
              let item = drag.flatMap({ current in builtItems.first { $0.id == current.id } }),
              Self.isRemovableByDrag(item)
        else { return false }
        if let name = item.widgetName {
            guard let isOn = DockSettings.widgetSwitches[name] else { return false }
            drag = nil
            settings[keyPath: isOn] = false
        } else {
            drag = nil
            unpin(item)
        }
        return true
    }

    /// A pinned app other than Finder, which is always there; a spacer; or a widget. An app that is
    /// only running is not in the dock to be taken out of it. Pure, for the tests.
    nonisolated static func isRemovableByDrag(_ item: DockItem) -> Bool {
        switch item.kind {
        case .app: item.isPinned && item.id != finderID
        case .spacer, .nowPlaying, .weather, .clock, .battery, .calendar, .keepAwake: true
        case .folder, .trash, .separator, .minimizedWindow, .runningApps: false
        }
    }

    /// Dropped on the bar: the order shown becomes the order kept. False when there was no drag in
    /// the bar to commit — a drop from Finder or from Settings, which the payload places instead.
    private func commitDrag() -> Bool {
        guard let current = drag, let gap = current.gap, gap < items.count, items[gap].id == current.id else {
            return false
        }
        let item = items[gap]
        if let name = item.widgetName {
            let next = gap + 1 < items.count ? items[gap + 1] : nil
            placeWidget(name, before: next.flatMap { $0.widgetName != nil ? $0 : nil })
        } else if let path = item.kind == .spacer ? item.id : item.url?.path {
            // The pinned list sees only pinned items, so the drop is before the next pinned one; the
            // running apps' places come from what the bar shows, which keeps them where they are.
            runningAnchors = Self.anchors(in: items, pinning: item.id)
            place(path, before: items[(gap + 1)...].first { $0.isPinned && ($0.kind == .app || $0.kind == .spacer) })
        }
        drag = nil
        // Rebuilt now, not at the settings' next change: a move among running apps changes no setting.
        rebuild()
        return true
    }

    /// Each unpinned running app's place in `shown`: the id of the pinned item before it, "" when
    /// none is. `pinning` counts as pinned, being the app the drop is pinning. Pure, for the tests.
    nonisolated static func anchors(in shown: [DockItem], pinning: String) -> [String: String] {
        var anchors: [String: String] = [:]
        var previous = ""
        for item in shown {
            if item.kind == .separator { break }
            if item.isPinned || item.id == pinning {
                previous = item.id
            } else if item.kind == .app {
                anchors[item.id] = previous
            }
        }
        return anchors
    }

    /// Reorders the widgets: `name` lands before `target`, or at the end. Pure, for the tests.
    nonisolated static func reordered(_ order: [String], moving name: String, before target: String?) -> [String] {
        var out = order.filter { $0 != name }
        if let target, let index = out.firstIndex(of: target) {
            out.insert(name, at: index)
        } else {
            out.append(name)
        }
        return out
    }

    nonisolated static let widgetIDPrefix = "widget:"

    func placeWidget(_ name: String, before target: DockItem?) {
        let targetName = target?.widgetName
        // Before the name check: a gallery widget dropped on itself is still a widget to add.
        WidgetsModel.shared.add(name)
        guard name != targetName else { return }
        // The bar shows the order with any missing widget appended, so reorder that: against the raw
        // list a drop before a missing widget found no target and went to the end. Names this build
        // does not know stay, as a newer build's synced order may carry them.
        let order = settings.widgetOrder
        let shown = order + canonicalWidgetOrder.filter { !order.contains($0) }
        settings.widgetOrder = Self.reordered(shown, moving: name, before: targetName)
    }

    /// Pins the app at `path` immediately before `target`, or at the end of the pinned apps. Moving an
    /// already pinned app is the same operation: take it out, put it back in.
    func place(_ path: String, before target: DockItem?) {
        guard let pinned = Self.placed(path, before: target, in: settings.pinnedApps) else { return }
        settings.pinnedApps = pinned
        let id = Self.pinnedID(path)
        // Pinning is an explicit ask to see the app, so it overrides an earlier Hide from Dock.
        settings.hiddenApps.removeAll { Self.key(URL(fileURLWithPath: $0)) == id }
    }

    /// `place`'s list work: the pinned list with `path` moved or added before `target`, or nil when
    /// the drop changes nothing. Pure, for the tests.
    ///
    /// Finder moves like any app. The list names it only once it has been moved from first place:
    /// it is worked on here with Finder written in, and Finder is dropped again if it ends up first,
    /// so a dock whose Finder was never moved keeps the list it always had.
    nonisolated static func placed(_ path: String, before target: DockItem?, in pinnedApps: [String]) -> [String]? {
        let isSpacer = path.hasPrefix(spacerPrefix)
        let id = pinnedID(path)
        guard path.hasSuffix(".app") || isSpacer, id != target?.id else { return nil }
        let namesFinder = pinnedApps.contains { pinnedID($0) == finderID }
        var pinned = (namesFinder ? pinnedApps : [finderPath] + pinnedApps).filter { pinnedID($0) != id }
        var index = pinned.count
        if let target, target.kind == .app || target.kind == .spacer, target.isPinned,
            let found = pinned.firstIndex(where: { pinnedID($0) == target.id }) {
            index = found
        }
        pinned.insert(path, at: index)
        if let first = pinned.first, pinnedID(first) == finderID { pinned.removeFirst() }
        return pinned == pinnedApps ? nil : pinned
    }

    /// A `pinnedApps` entry's item id: a spacer is its own id, an app its resolved path.
    private nonisolated static func pinnedID(_ entry: String) -> String {
        entry.hasPrefix(spacerPrefix) ? entry : key(URL(fileURLWithPath: entry))
    }

    // MARK: - Drag and drop

    func dragPayload(for item: DockItem) -> NSItemProvider {
        // Asked for as the drag starts, so it is where the icon lifts out of the bar.
        beginDrag(item)
        // Spacers and widgets drag by their identity strings, exactly as an app drags by its path.
        if item.kind == .spacer || item.widgetName != nil {
            return Self.ownProcessPayload(item.id)
        }
        guard item.kind == .app, let url = item.url else { return NSItemProvider() }
        let provider = NSItemProvider()
        let data = Data(url.path.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: dragType.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    /// A widget dragged out of Settings' gallery: the payload a tile on the bar drags, so the bar's
    /// drop handling places it wherever it lands.
    static func dragPayload(forWidget name: String) -> NSItemProvider {
        ownProcessPayload(widgetIDPrefix + name)
    }

    /// A spacer or divider dragged out of Settings' gallery, under a fresh entry: as for a widget,
    /// the bar's drop handling places it where it lands.
    static func dragPayload(forNewSpacer entry: String) -> NSItemProvider {
        ownProcessPayload(entry)
    }

    private static func ownProcessPayload(_ id: String) -> NSItemProvider {
        let provider = NSItemProvider()
        let payload = Data(id.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: dragType.identifier, visibility: .ownProcess) {
            completion in
            completion(payload, nil)
            return nil
        }
        return provider
    }

    /// A drop on an icon (`target`) or on the bar itself (nil).
    func handleDrop(_ providers: [NSItemProvider], onto target: DockItem?) -> Bool {
        // The release of a drag Esc cancelled: only one drag session runs at a time, so this drop
        // is its own; read on, the payload would move or pin the item the cancel put back.
        if let current = drag, current.cancelled {
            endDrag()
            return true
        }
        // A bar drag let go on the Trash takes the item off the bar, as the macOS Dock does, or goes
        // back when it cannot come off: the gap is pinned to the end of the section over it, so
        // committing would pin a running app or move Finder.
        if target?.kind == .trash, drag != nil {
            if !endDragRemoving() { endDrag() }
            return true
        }
        if commitDrag() { return true }
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        if files.isEmpty {
            guard let provider = providers.first(where: {
                $0.hasItemConformingToTypeIdentifier(dragType.identifier)
            }) else { return false }
            _ = provider.loadDataRepresentation(forTypeIdentifier: dragType.identifier) { [weak self] data, _ in
                guard let data, let path = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in
                    // A tile dragged out of the running-apps tile, or a gallery widget, has no drag
                    // to put back: dropped on the Trash it is a no-op, not a place to pin it.
                    guard target?.kind != .trash else { return }
                    if path.hasPrefix(Self.widgetIDPrefix) {
                        self?.placeWidget(String(path.dropFirst(Self.widgetIDPrefix.count)), before: target)
                    } else if target?.kind != .runningApps {
                        // An app dropped back on its own tile would be appended to the pins.
                        self?.place(path, before: target)
                    }
                }
            }
            return true
        }
        Task {
            var urls: [URL] = []
            for provider in files {
                if let url = await loadURL(provider) { urls.append(url) }
            }
            drop(urls, onto: target)
        }
        return true
    }

    /// A mounted volume other than the startup disk, which cannot be ejected, and other than the
    /// system's hidden ones — Preboot, VM, Update and the like are volumes too, and only
    /// browsability tells them apart (measured on macOS 27.2; the Data volume reads as the root).
    nonisolated static func isEjectableVolume(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isVolumeKey, .volumeIsRootFileSystemKey, .volumeIsBrowsableKey])
        else { return false }
        return values.isVolume == true && values.volumeIsRootFileSystem != true && values.volumeIsBrowsable == true
    }

    /// Off the main thread: the unmount waits for the disk to flush, which can take seconds, and the
    /// dock would stop tracking the pointer meanwhile. A disk in use stays mounted, and says so, as
    /// Finder does — otherwise the drop would look like it did nothing. Several disks go one after
    /// another and fail in one alert: an alert each opened one modal on top of the last.
    private func eject(_ volumes: [URL]) {
        guard !volumes.isEmpty else { return }
        Task.detached {
            var failed: [(URL, Error)] = []
            for volume in volumes {
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
                } catch {
                    failed.append((volume, error))
                }
            }
            guard !failed.isEmpty else { return }
            await MainActor.run { Self.explainEjectFailed(failed) }
        }
    }

    private static func explainEjectFailed(_ failed: [(URL, Error)]) {
        let names = failed.map { "“\(FileManager.default.displayName(atPath: $0.0.path))”" }
        let alert = NSAlert()
        alert.messageText = "DockPlus couldn't eject \(names.formatted())"
        var seen = Set<String>()
        alert.informativeText = failed.map { $0.1.localizedDescription }
            .filter { seen.insert($0).inserted }
            .joined(separator: "\n")
        // DockPlus is a background app; without this the alert can open behind other windows.
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    private func drop(_ urls: [URL], onto target: DockItem?) {
        guard !urls.isEmpty else { return }
        if target?.kind == .trash {
            // A disk dropped on the Trash is ejected, as in the macOS Dock; recycling one only fails.
            let volumes = urls.filter(Self.isEjectableVolume)
            eject(volumes)
            let files = urls.filter { !volumes.contains($0) }
            guard !files.isEmpty else { return }
            NSWorkspace.shared.recycle(files) { [weak self] _, _ in
                Task { @MainActor in self?.refreshTrash() }
            }
            return
        }
        if urls.allSatisfy({ $0.pathExtension == "app" }) {
            for url in urls { place(url.path, before: target) }
            return
        }
        if let target, target.kind == .app, let app = target.url {
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        if target == nil || target?.kind == .folder, !folders.isEmpty {
            settings.stacks += folders.map(\.path).filter { !settings.stacks.contains($0) }
        }
    }
}
