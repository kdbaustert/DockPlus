import AppKit

extension DockModel {
    /// The minimized-window and badge sweeps, off the main thread: each app that does not answer
    /// costs its 0.3 s timeout, and on the main thread that froze magnification and clicks with it.
    /// Serial, so the two sweeps — and a context menu's window list — never ask at once.
    private static let axQueue = DispatchQueue(label: "dev.kennyb.dockplus.ax", qos: .utility)

    /// Minimized is each app's own word for it: the windows it lists over Accessibility with
    /// AXMinimized set. Inferring it from the window server — off screen and on no Space — let
    /// phantoms through (Teams' shell window and a Rio leftover, measured) and would count whole
    /// other Desktops on macOS 26. The accepted trade-off: Electron apps list no AX windows at all,
    /// so their minimized windows get no tile.
    ///
    /// Only checked, never prompted for: this runs off a timer, and the prompt belongs to a click.
    ///
    /// `only` asks just those apps and keeps what the last sweep found for the rest; nil asks
    /// every regular app.
    func refreshMinimizedWindows(only pids: Set<pid_t>? = nil) {
        guard settings.showsMinimizedWindows, AXIsProcessTrusted(), WindowActions.getWindowIDFn != nil else {
            if !minimizedWindows.isEmpty {
                minimizedWindows = []
                rebuild()
            }
            needsFullMinimizedSweep = true
            // Pruned only by a sweep, which no longer runs: without this the pictures stayed held.
            if !minimizedThumbs.isEmpty { minimizedThumbs = [:] }
            return
        }
        // A sweep still waiting on a slow app: the next beat asks again.
        guard !isSweepingMinimized else { return }
        isSweepingMinimized = true
        let pids = needsFullMinimizedSweep ? nil : pids
        needsFullMinimizedSweep = false
        let me = ProcessInfo.processInfo.processIdentifier
        // Running order, so a partial pass keeps the tiles where they were.
        let order = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me }
            .map(\.processIdentifier)
        let asked = pids.map { set in order.filter(set.contains) } ?? order
        Self.axQueue.async { [weak self] in
            let answers = Dictionary(uniqueKeysWithValues: asked.map { ($0, Self.minimizedWindows(of: $0)) })
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.applyMinimizedWindows(order: order, answers: answers) }
            }
        }
    }

    /// The pid and each ordinary window of the app with whether it is on screen, from the window
    /// server alone: no round trip to the app, and no Screen Recording needed for ids and flags.
    /// Compared beat to beat to tell whether the app's windows could have been minimized or restored.
    nonisolated static func windowSignature(of pid: pid_t?) -> [Int] {
        guard let pid,
              let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let windows = info.compactMap { window -> Int? in
            guard window[kCGWindowOwnerPID as String] as? pid_t == pid,
                  window[kCGWindowLayer as String] as? Int == 0,
                  let number = window[kCGWindowNumber as String] as? Int
            else { return nil }
            return number << 1 | ((window[kCGWindowIsOnscreen as String] as? Bool) == true ? 1 : 0)
        }
        return [Int(pid)] + windows.sorted()
    }

    /// One app's minimized windows. Off the main thread; see `axQueue`.
    private nonisolated static func minimizedWindows(of pid: pid_t) -> [MinimizedWindow] {
        guard let windows = WindowActions.windows(of: pid) else { return [] }
        var found: [MinimizedWindow] = []
        for window in windows where WindowActions.isMinimized(window) {
            guard let id = WindowActions.windowID(of: window) else { continue }
            // The AX title, which needs no Screen Recording, unlike the window server's.
            let title = WindowActions.string(of: window, kAXTitleAttribute) ?? ""
            found.append(MinimizedWindow(id: id, pid: pid, title: title))
        }
        return found
    }

    private func applyMinimizedWindows(order: [pid_t], answers: [pid_t: [MinimizedWindow]]) {
        isSweepingMinimized = false
        guard settings.showsMinimizedWindows else { return }
        let found = Self.merged(order: order, answers: answers, previous: minimizedWindows)
        let known = Set(minimizedWindows.map(\.identity))
        guard Set(found.map(\.identity)) != known else { return }
        let fresh = found.filter { !known.contains($0.identity) }
        minimizedWindows = found
        minimizedThumbs = minimizedThumbs.filter { thumb in found.contains { $0.id == thumb.key } }
        rebuild()
        // Thumbnails arrive late and only for windows still minimized then. Only with Screen
        // Recording already granted: asking for it belongs to a hover over a preview, not to a
        // window someone happened to minimize.
        guard WindowCapture.canCapture, !fresh.isEmpty else { return }
        Task { [weak self] in
            let thumbs = await WindowCapture.windowThumbnails(ids: fresh.map(\.id), maxHeight: 120)
            guard let self else { return }
            for window in fresh {
                guard let thumb = thumbs.first(where: { $0.id == window.id }),
                      minimizedWindows.contains(where: { $0.identity == window.identity })
                else { continue }
                minimizedThumbs[window.id] = NSImage(cgImage: thumb.image, size: .zero)
            }
        }
    }

    /// A sweep's answers laid over the last sweep's windows, in running order: apps that were not
    /// asked keep what the last sweep found for them. Pure, for the tests.
    nonisolated static func merged(
        order: [pid_t], answers: [pid_t: [MinimizedWindow]], previous: [MinimizedWindow]
    ) -> [MinimizedWindow] {
        order.flatMap { pid in answers[pid] ?? previous.filter { $0.pid == pid } }
    }

    /// A running app's windows for its context menu. Called as the menu is built, which SwiftUI
    /// does when the menu opens, not along with the icon (measured) — so this asks nothing until
    /// someone right-clicks. The answer comes back off the main thread, like the sweeps', into
    /// `menuWindows`, which the menu reads: SwiftUI builds the open menu's content again when it
    /// changes (measured; that the menu on screen redraws with it was not confirmed). That rebuild
    /// calls this again, hence the one-second rule — without it each answer would ask once more.
    func requestMenuWindows(for pid: pid_t) {
        guard AXIsProcessTrusted(), WindowActions.getWindowIDFn != nil else { return }
        if let asked = menuWindowsAsked[pid], Date().timeIntervalSince(asked) < 1 { return }
        menuWindowsAsked[pid] = Date()
        Self.axQueue.async { [weak self] in
            let found = MenuWindows(pid: pid, windows: Self.menuWindows(of: pid))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, found != self.menuWindows[pid] else { return }
                    self.menuWindows[pid] = found
                }
            }
        }
    }

    /// Off the main thread; see `axQueue`.
    private nonisolated static func menuWindows(of pid: pid_t) -> [MenuWindows.Window] {
        menuWindows(from: (WindowActions.windows(of: pid) ?? []).map { window in
            (WindowActions.windowID(of: window), WindowActions.string(of: window, kAXTitleAttribute),
             WindowActions.string(of: window, kAXSubroleAttribute))
        })
    }

    /// What the menu lists: standard windows — not panels, sheets or palettes — with a title to show
    /// and an id to raise them by. Pure, for the tests.
    nonisolated static func menuWindows(
        from windows: [(id: CGWindowID?, title: String?, subrole: String?)]
    ) -> [MenuWindows.Window] {
        windows.compactMap { window in
            guard let id = window.id, let title = window.title, !title.isEmpty,
                  window.subrole == kAXStandardWindowSubrole
            else { return nil }
            return MenuWindows.Window(id: id, title: title)
        }
    }

    /// Apps set their badge on their Dock tile, and macOS hands it to the real Dock, which is still
    /// running under DockPlus, only hidden. That Dock lists each tile over Accessibility with the badge
    /// as `AXStatusLabel` beside the app's `AXURL`, so this reads them back. Measured: one sweep of
    /// 23 tiles takes about a millisecond, and a new badge shows there within a second or two.
    func refreshBadges() {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else {
            if !badges.isEmpty { badges = [:] }
            return
        }
        guard !isSweepingBadges else { return }
        isSweepingBadges = true
        let pid = dock.processIdentifier
        Self.axQueue.async { [weak self] in
            let found = Self.badges(from: Self.dockTiles(pid: pid))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isSweepingBadges = false
                    if found != self.badges { self.badges = found }
                }
            }
        }
    }

    /// Each Dock tile's URL and badge. Off the main thread; see `axQueue`.
    private nonisolated static func dockTiles(pid: pid_t) -> [(url: URL?, label: String?)] {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.3)
        var tiles: [(url: URL?, label: String?)] = []
        for list in WindowActions.children(of: element) {
            for tile in WindowActions.children(of: list) {
                var values: CFArray?
                guard AXUIElementCopyMultipleAttributeValues(
                    tile, [kAXURLAttribute, "AXStatusLabel"] as CFArray, [], &values) == .success,
                    let values = values as? [Any], values.count == 2
                else { continue }
                tiles.append((values[0] as? URL, values[1] as? String))
            }
        }
        return tiles
    }

    /// The badges by item id. Only apps' tiles carry a URL; an empty label is no badge. Pure, for the
    /// tests.
    nonisolated static func badges(from tiles: [(url: URL?, label: String?)]) -> [String: String] {
        var out: [String: String] = [:]
        for tile in tiles {
            guard let url = tile.url, url.isFileURL, let label = tile.label, !label.isEmpty else { continue }
            out[key(url)] = label
        }
        return out
    }
}
