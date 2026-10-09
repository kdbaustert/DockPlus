import AppKit
import Observation
import SwiftUI

struct DockItem: Identifiable, Equatable, Sendable {
    enum Kind: Sendable {
        case app, folder, trash, separator, spacer, minimizedWindow, nowPlaying, weather, clock, battery, calendar,
             runningApps, keepAwake
    }

    let id: String
    let kind: Kind
    let url: URL?
    let name: String
    let isPinned: Bool
    let isRunning: Bool
    let pid: pid_t?
    /// The window a `.minimizedWindow` tile stands for.
    var windowID: CGWindowID?
    /// And the app that window belongs to, for VoiceOver — looked up once per rebuild, not per render.
    var appName: String?
    /// The apps a `.runningApps` tile collected: carried on the item, so a change to them is a change
    /// to the bar's items and rebuilds it like any other.
    var apps: [DockItem] = []

    /// The widget this tile stands for, parsed out of its "widget:" id; nil for everything else.
    var widgetName: String? {
        id.hasPrefix(DockModel.widgetIDPrefix) ? String(id.dropFirst(DockModel.widgetIDPrefix.count)) : nil
    }

    /// How much of the bar the item takes. The widget widths are fixed points: their content is
    /// text, which does not scale with the icons.
    func spec(for m: DockMetrics) -> DockItemSpec {
        switch kind {
        case .app, .folder, .trash: .icon(m)
        case .minimizedWindow: .init(resting: m.iconSize * 1.4, magnifies: false)
        case .separator: .fixed(m.separatorExtent)
        case .spacer: id.hasPrefix(dividerPrefix) ? .fixed(m.separatorExtent) : .fixed(m.iconSize * 0.55)
        case .nowPlaying: .fixed(180)
        case .weather: .fixed(128)
        case .clock: .fixed(84)
        case .battery: .fixed(84)
        case .calendar: .fixed(156)
        case .keepAwake: .fixed(108)
        case .runningApps: .fixed(Self.runningAppsWidth(count: apps.count, height: m.iconSize))
        }
    }

    // The running-apps tile's geometry, which both its width here and its drawing in WidgetTiles read.

    /// Icons shown before the last slot becomes a "+N" for the rest.
    static let runningAppsShown = 8
    static let runningAppsGap: CGFloat = 3
    static let runningAppsInset: CGFloat = 7

    static func runningAppsIconSize(height: CGFloat) -> CGFloat { (height * 0.62).rounded() }

    /// Wide enough for `count` icons, up to `runningAppsShown` slots.
    static func runningAppsWidth(count: Int, height: CGFloat) -> CGFloat {
        let slots = CGFloat(min(max(count, 1), runningAppsShown))
        return 2 * runningAppsInset + slots * runningAppsIconSize(height: height) + (slots - 1) * runningAppsGap
    }
}

/// Spacers persist inside `pinnedApps` so they order and drag like everything else there.
let spacerPrefix = "spacer:"
/// A divider is a spacer that draws the separator's line. Its entry keeps the spacer prefix, so it
/// orders, drags and is removed exactly as a spacer is, by everything that already handles those.
let dividerPrefix = spacerPrefix + "divider:"

struct MinimizedWindow: Equatable, Sendable {
    let id: CGWindowID
    let pid: pid_t
    let title: String

    /// Which window this is, title aside: a title that changes while minimized (a player's track,
    /// a terminal's command) is not a different window and must not rebuild or re-screenshot it.
    struct Identity: Hashable { let id: CGWindowID; let pid: pid_t }
    var identity: Identity { Identity(id: id, pid: pid) }
}

/// A running app's windows, as its context menu lists them.
struct MenuWindows: Equatable, Sendable {
    struct Window: Equatable, Sendable {
        let id: CGWindowID
        let title: String
    }

    let pid: pid_t
    let windows: [Window]
}

@MainActor
@Observable
final class MenuOpenToken {
    var opens = 0
}

@MainActor
@Observable
final class DockModel {
    nonisolated static let finderPath = "/System/Library/CoreServices/Finder.app"
    nonisolated static let finderID = key(URL(fileURLWithPath: finderPath))

    /// What the bar shows: the built items, rearranged while an icon is dragged along it.
    private(set) var items: [DockItem] = []
    /// The items as the settings and running apps make them, before a drag rearranges them.
    @ObservationIgnored var builtItems: [DockItem] = []
    /// An icon being dragged along the bar, and where its gap is. See DockModel+DragDrop.swift.
    var drag: DockDrag? { didSet { showItems() } }
    /// Where each unpinned running app stands among the pinned ones: the id of the item it follows,
    /// "" for first. Only for apps a drop has placed; the rest come after the pinned apps. Kept for
    /// this run only, and only while the app runs — it has no place to come back to once it quits.
    @ObservationIgnored var runningAnchors: [String: String] = [:]
    private(set) var trashIsFull = false
    // The sweeps' results, and their in-flight flags below, are not `private`: the sweeps that set
    // them live in DockModel+Sweeps.swift, and Swift has no access level for "this type, any file".
    /// Windows currently in the Dock's sense of minimized — tiles between the separator and Trash.
    var minimizedWindows: [MinimizedWindow] = []
    /// Their thumbnails, tracked so the tile redraws when a late capture lands.
    var minimizedThumbs: [CGWindowID: NSImage] = [:]
    /// Item ids of apps between starting to launch and finishing — their icons bounce.
    private(set) var launching: Set<String> = []
    /// Each app's badge — an unread count, usually — by item id.
    var badges: [String: String] = [:]
    /// The windows each app's context menu asked for, by pid. Not one slot for the open menu: SwiftUI
    /// keeps every menu it has built observing this, so with one slot two apps' menus took it from
    /// each other forever and the open one flashed (measured). See `requestMenuWindows` in
    /// DockModel+Sweeps.swift.
    var menuWindows: [pid_t: MenuWindows] = [:]
    @ObservationIgnored var menuWindowsAsked: [pid_t: Date] = [:]
    /// One counter per item, bumped when that item's menu opens, for a menu that shows what nothing
    /// observed announces — the Space in front, macOS's own settings — to read: SwiftUI rebuilds a
    /// menu it built before only when something it observes changes (measured: Finder's, built on
    /// Desktop 4, still offered Desktop 4 as This Desktop on Desktop 5). Per item, not one global
    /// count: every menu SwiftUI has built stays alive observing, and a shared count re-ran the
    /// expensive Options content of all of them each time any menu opened.
    @ObservationIgnored private var menuTokens: [String: MenuOpenToken] = [:]

    @ObservationIgnored let settings: DockSettings
    /// Opens a Grid stack's grid from the dock it was clicked on, answering whether one did. Set by
    /// the app delegate, which holds the docks: the model sees the click, and only a dock knows where
    /// the icon is.
    @ObservationIgnored var showStackGrid: ((DockItem) -> Bool)?
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    /// Bumped when a cached icon is dropped, so the tiles redraw and refetch. `icon(for:)` reads it,
    /// and the tiles call that from their bodies, which registers the dependency; the cache itself
    /// stays unobserved because `icon(for:)` also fills it mid-render.
    private var iconsVersion = 0
    /// Each app tile's bundle modification date at the last icon sweep, by item id.
    @ObservationIgnored private var iconStamps: [String: Date] = [:]
    @ObservationIgnored private var isSweepingIcons = false

    /// The longest an icon bounces. An app that never reports finishing its launch — one that hangs,
    /// or is stopped by Gatekeeper — would otherwise bounce forever.
    private static let launchTimeout: TimeInterval = 15
    /// One bounce — the keyframes in DockIcon (0.3 up + 0.3 down). A bounce only ever stops at the
    /// end of a whole cycle: stopping mid-flight would drop the icon back onto the bar in one frame.
    /// That also means a launch always shows at least one bounce — measured, TextEdit reports
    /// finishing 50 ms after starting, which cut the bounce off before a frame of it was drawn.
    private nonisolated static let bounceCycle: TimeInterval = 0.6
    @ObservationIgnored private var launchStarts: [String: Date] = [:]
    @ObservationIgnored private var runningObservation: NSKeyValueObservation?
    /// What the running apps looked like at the last rebuild; see the maintenance timer.
    @ObservationIgnored private var lastRunningSignature: [pid_t: URL?] = [:]
    /// Counts the maintenance timer's beats, for the minimized windows' periodic full sweep.
    @ObservationIgnored private var maintenanceBeats = 0
    /// The frontmost app's pid and its windows (see `windowSignature`) at the last beat.
    @ObservationIgnored private var lastWindowSignature: [Int] = []
    /// The frontmost app at the last activation — the app a switch just left, whose windows the
    /// activation sweep must still ask about.
    @ObservationIgnored private var lastFrontmostPID: pid_t?
    @ObservationIgnored var isSweepingMinimized = false
    /// What sweeps were asked for while one was running, which the finished sweep runs next.
    @ObservationIgnored var queuedSweep = QueuedSweep()
    /// Set while the minimized-window sweep is ineligible (setting off, no Accessibility), so the
    /// first sweep after it passes again asks every app instead of waiting for the 30 s full one.
    @ObservationIgnored var needsFullMinimizedSweep = false
    @ObservationIgnored var isSweepingBadges = false
    @ObservationIgnored private var maintenanceTimer: Timer?
    @ObservationIgnored private var isRebuildPending = false

    init(settings: DockSettings) {
        self.settings = settings
        let center = NSWorkspace.shared.notificationCenter
        // "Will launch" as well as "did": an app started anywhere — Spotlight, Finder, a link — bounces,
        // as it does in the real Dock, not only one clicked here.
        // Not DockPlus's own: the now-playing poll's osascript children register under its bundle
        // (see `rebuild`), and each launch and exit was a rebuild and a re-render of every icon.
        let myBundleID = Bundle.main.bundleIdentifier
        center.addObserver(forName: NSWorkspace.willLaunchApplicationNotification, object: nil, queue: .main) {
            [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard myBundleID == nil || app?.bundleIdentifier != myBundleID else { return }
            let url = app?.bundleURL
            MainActor.assumeIsolated {
                if let url { self?.startedLaunching(url) }
                // An app that is not pinned has no icon until it is in the running list, so it
                // gets one now to bounce, rather than appearing only once it has finished.
                self?.scheduleRebuild()
            }
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard myBundleID == nil || app?.bundleIdentifier != myBundleID else { return }
                let url = app?.bundleURL
                MainActor.assumeIsolated {
                    if let url {
                        self?.finishedLaunching(url)
                        if name == NSWorkspace.didTerminateApplicationNotification { self?.recordQuit(url) }
                    }
                    self?.scheduleRebuild()
                }
            }
        }
        // On NSWorkspace, which lives as long as the process — never on the NSRunningApplication
        // objects themselves. Per-app KVO on `activationPolicy` was tried and crashed (SIGSEGV in
        // AppKit's runningApplicationNotificationCallback, report 2026-09-28-102833): AppKit can
        // deallocate an app's record while it is still observed. Policy flips with no membership
        // change are caught by the timer below instead. Every Launch Services process fires this,
        // background agents and DockPlus's own osascript children included, so it rebuilds only when
        // the regular apps differ.
        runningObservation = NSWorkspace.shared.observe(\.runningApplications) {
            @Sendable [weak self] _, _ in
            Task { @MainActor in self?.scheduleRebuildIfRunningAppsChanged() }
        }
        rebuild()
        refreshTrash()
        // The baseline right away, not at the first beat: an icon updated in the first six seconds
        // would otherwise be compared against a date that was never taken.
        refreshIcons()
        // Likewise, rather than leaving tiles and badges missing until the first full beat.
        refreshMinimizedWindows()
        refreshBadges()
        trackItems()
        // Minimized windows: on every app switch, ask the app just left — the one that may have
        // minimized its last window on the way out — and the one arrived; on the timer below, the
        // frontmost app each beat and every app each 15th (30 s). Asking every app on each switch
        // was a round trip per regular app per Cmd-Tab (2-3 ms each, measured, and a slow one costs
        // its 0.3 s timeout), all serialized ahead of any right-click's window list. Badges too:
        // switching to an app is usually reading what its badge counted, and the count should clear
        // then, not at the next slow sweep.
        lastFrontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) {
            [weak self] note in
            let activated = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .processIdentifier
            MainActor.assumeIsolated {
                guard let self else { return }
                let pids = Set([activated, self.lastFrontmostPID].compactMap(\.self))
                self.lastFrontmostPID = activated ?? self.lastFrontmostPID
                self.refreshMinimizedWindows(only: pids.isEmpty ? nil : pids)
                self.refreshBadges()
            }
        }
        startMaintenance()
    }

    /// How often `id`'s menu has opened. Read from the menu's body, which registers the dependency.
    func menuOpens(of id: String) -> Int { menuToken(id).opens }

    /// `id`'s menu is opening: only that menu rebuilds.
    func menuOpened(_ id: String) { menuToken(id).opens += 1 }

    private func menuToken(_ id: String) -> MenuOpenToken {
        if let token = menuTokens[id] { return token }
        let token = MenuOpenToken()
        menuTokens[id] = token
        return token
    }

    /// Things reach the Trash from Finder with nothing announced to DockPlus, and it cannot watch a
    /// folder it is not allowed to open. Two `stat` calls every couple of seconds costs nothing.
    /// The running-app check sweeps up what no notification announces — chiefly an app switching
    /// its activation policy to become a regular app after launch. Only the check runs here, not
    /// a rebuild: a rebuild touches the disk for every pinned app and stack, and one stack on a
    /// dead SMB share would freeze the dock every two seconds.
    ///
    /// The running-app check and the badge sweep run every third beat (6 s). Each is a trip to
    /// another process — about 4 ms of Launch Services for the first, the Dock over Accessibility
    /// for the second — and neither is something anyone watches to the second: a policy flip is
    /// rare, launches and quits are announced, and a badge is also swept on every app switch.
    private func startMaintenance() {
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.maintenanceBeats += 1
                self.refreshTrash()
                // The frontmost app is asked over Accessibility only when the window server says its
                // windows changed — that wakes the app, where the window server's list does not. A
                // minimize or restore flips a window's on-screen flag, so it still shows within a beat.
                // Off, the call is what clears the tiles, so it is not skipped; nor is the first one
                // after it was ineligible, which asks every app whether or not the windows changed.
                // The signature is evaluated first either way, so it stays current.
                if self.maintenanceBeats % 15 == 0 {
                    self.lastWindowSignature = Self.windowSignature(
                        of: NSWorkspace.shared.frontmostApplication?.processIdentifier)
                    self.refreshMinimizedWindows()
                } else if self.frontmostWindowsChanged() || self.needsFullMinimizedSweep
                            || !self.settings.showsMinimizedWindows {
                    self.refreshMinimizedWindows(only: NSWorkspace.shared.frontmostApplication.map {
                        [$0.processIdentifier]
                    })
                }
                if self.maintenanceBeats % 3 == 0 {
                    self.rebuildIfRunningAppsChanged()
                    self.refreshBadges()
                    self.refreshIcons()
                }
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        maintenanceTimer = timer
    }

    private func frontmostWindowsChanged() -> Bool {
        let now = Self.windowSignature(of: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        defer { lastWindowSignature = now }
        return now != lastWindowSignature
    }

    /// Stopped while nobody can see the dock; see AppDelegate. Waking catches up at once on
    /// everything the beat would have noticed in the meantime.
    func setPaused(_ paused: Bool) {
        if paused {
            maintenanceTimer?.invalidate()
            maintenanceTimer = nil
            return
        }
        guard maintenanceTimer == nil else { return }
        startMaintenance()
        rebuild()
        refreshTrash()
        refreshMinimizedWindows()
        refreshBadges()
        refreshIcons()
    }

    /// Rebuilds whenever the pinned apps or stacks change, whether the dock itself changed them or
    /// the Applications or Stacks tab in Settings did.
    private func trackItems() {
        observeContinuously(ownedBy: self) { [settings] in
            _ = (settings.pinnedApps, settings.stacks, settings.hiddenApps,
                 settings.showsMinimizedWindows, settings.showsNowPlaying, settings.showsWeather,
                 settings.showsClock, settings.showsBattery, settings.showsCalendar, settings.showsRunningApps,
                 settings.showsKeepAwake,
                 settings.widgetOrder,
                 settings.edge, settings.showsRecentApps)
        } onChange: { [weak self] in
            // Switching recents off forgets the list: the settings footer says it is kept only
            // while the switch is on, and a stale one came back when it was turned on again.
            if let settings = self?.settings, !settings.showsRecentApps, !settings.recentApps.isEmpty {
                settings.recentApps = []
            }
            self?.rebuild()
        }
    }

    var metrics: DockMetrics {
        DockMetrics(
            iconSize: settings.iconSize,
            magnifiedSize: settings.magnifies ? max(settings.magnifiedSize, settings.iconSize) : settings.iconSize,
            spacing: settings.iconPadding,
            padding: settings.dockPadding
        )
    }

    /// Everything a layout is built from, so an unchanged one is not built again.
    struct LayoutKey: Equatable {
        let items: [DockItem]
        let metrics: DockMetrics
        let stripLength: CGFloat
        let pointer: CGFloat?
        let gain: CGFloat
        let reach: Double
    }

    /// The bar's geometry for one screen's panel, with the icons shrunk to fit that screen's edge.
    /// The falloff carries the Reach setting and the panel's approach gain, so the pure geometry
    /// stays free of both. Cached per panel: the pointer tick (up to 120 Hz) and the view's body both
    /// ask for it, with the same inputs, for every pointer move — and each build is a handful of
    /// arrays. Callers take the metrics from the result, since fitting can change the icon size.
    func layout(for state: PanelState) -> DockLayout {
        let key = LayoutKey(
            items: items, metrics: metrics, stripLength: state.stripLength, pointer: state.pointer,
            gain: state.gain, reach: settings.magnifyReach)
        if let cached = state.layoutCache, cached.key == key { return cached.layout }
        let layout = layout(of: items, for: state)
        state.layoutCache = (key, layout)
        return layout
    }

    /// The geometry of `items` on `state`'s panel — `layout(for:)` without the cache, for a bar that
    /// is not the one shown: `moveDrag` builds the bar a candidate gap would give to check the
    /// pointer would still be on the dragged item's slot.
    func layout(of items: [DockItem], for state: PanelState) -> DockLayout {
        let reach = settings.magnifyReach
        let gain = state.gain
        // Some room at either end, as the macOS Dock leaves.
        let fitted = DockLayout.fitted(metrics, available: state.stripLength - 16) { m in
            items.map { $0.spec(for: m) }
        }
        return DockLayout(
            items: items.map { $0.spec(for: fitted) },
            metrics: fitted,
            stripLength: state.stripLength,
            pointer: state.pointer,
            falloff: { distance, iconSize in
                magnificationFalloff(distance: distance, iconSize: iconSize, reachIcons: reach) * gain
            }
        )
    }

    // MARK: - Items

    /// Publishes the built items with the drag applied. Called for either changing; here rather than
    /// beside the drag because only this file may set `items`.
    func showItems() {
        let shown = Self.arranged(builtItems, drag: drag)
        if shown != items { items = shown }
    }

    /// The apps that get a tile: regular ones, not DockPlus. By bundle as well as pid: the now-playing
    /// poll's osascript children register under DockPlus's bundle as regular apps, and each flashed
    /// a tile for its tenth of a second.
    private static func regularApps(_ all: [NSRunningApplication]) -> [NSRunningApplication] {
        let me = ProcessInfo.processInfo.processIdentifier
        let myBundleID = Bundle.main.bundleIdentifier
        return all.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != me
                && (myBundleID == nil || $0.bundleIdentifier != myBundleID)
        }
    }

    /// The regular apps and where each lives — in-memory reads only, no disk.
    private static func runningSignature(_ apps: [NSRunningApplication]) -> [pid_t: URL?] {
        Dictionary(regularApps(apps).map { ($0.processIdentifier, $0.bundleURL) }) { first, _ in first }
    }

    private func rebuildIfRunningAppsChanged() {
        if Self.runningSignature(NSWorkspace.shared.runningApplications) != lastRunningSignature { rebuild() }
    }

    private func scheduleRebuildIfRunningAppsChanged() {
        if Self.runningSignature(NSWorkspace.shared.runningApplications) != lastRunningSignature {
            scheduleRebuild()
        }
    }

    /// One rebuild on the next turn of the run loop for however many asked in this one. A launch
    /// alone announces itself three or four times — will launch, the running-apps KVO, did launch —
    /// and each rebuild touches the disk for every pinned app and stack, on the main thread.
    private func scheduleRebuild() {
        guard !isRebuildPending else { return }
        isRebuildPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.isRebuildPending = false
                self?.rebuild()
            }
        }
    }

    func rebuild() {
        let all = NSWorkspace.shared.runningApplications
        lastRunningSignature = Self.runningSignature(all)
        let running = Self.regularApps(all)
        // From the one table that names every widget's switch, so a widget added there is enabled
        // here without a second list to forget.
        var enabledWidgets = Set(DockSettings.widgetSwitches.filter { settings[keyPath: $0.value] }.keys)
        if !WidgetsModel.hasBattery { enabledWidgets.remove("battery") }
        let result = Self.items(
            pinned: settings.pinnedApps, hidden: settings.hiddenApps, stacks: settings.stacks,
            running: running.map(RunningApp.init), recent: settings.showsRecentApps ? settings.recentApps : [],
            minimized: minimizedWindows,
            widgetOrder: settings.widgetOrder, enabledWidgets: enabledWidgets, edge: settings.edge,
            anchors: runningAnchors,
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            isFolder: { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            },
            displayName: { FileManager.default.displayName(atPath: $0) }
        )
        // An app with no bundle has no file to take an icon from; its process has one.
        for app in running where app.bundleURL == nil {
            if let icon = app.icon { icons[RunningApp(app).id] = icon }
        }

        builtItems = result
        showItems()
        // An app that quit loses its place: it comes back at the end, as in the macOS Dock.
        let runningIDs = Set(running.map { RunningApp($0).id })
        runningAnchors = runningAnchors.filter { runningIDs.contains($0.key) }
        // The context-menu caches too: entries are per right-clicked pid and otherwise only ever
        // grew, and a recycled pid would briefly show the dead app's window titles. `menuWindows`
        // is observed by every cached menu, so it is only touched when something is actually gone.
        let runningPids = Set(running.map(\.processIdentifier))
        menuWindowsAsked = menuWindowsAsked.filter { runningPids.contains($0.key) }
        if menuWindows.contains(where: { !runningPids.contains($0.key) }) {
            menuWindows = menuWindows.filter { runningPids.contains($0.key) }
        }
        // Only what is on the bar: apps come and go all day, and an app with no bundle gets a new
        // "pid:" key at every launch, so the cache otherwise only ever grew.
        let onBar = Set(result.flatMap { [$0.id] + $0.apps.map(\.id) })
        icons = icons.filter { onBar.contains($0.key) }
        menuTokens = menuTokens.filter { onBar.contains($0.key) }
    }

    /// A running app as the item list needs it: plain values, so the list can be built in a test.
    struct RunningApp: Sendable {
        let pid: pid_t
        let bundleURL: URL?
        let name: String

        /// Its item id: the bundle's resolved path, or the pid for an app with no bundle.
        var id: String { bundleURL.map(DockModel.key) ?? "pid:\(pid)" }
    }

    /// The bar's items in order: Finder, the pinned apps and spacers, the running apps not already
    /// there, the recent apps behind a separator of their own, the separator, the stacks, the
    /// minimized windows, the Trash, then the widgets. With the running-apps widget on a bottom
    /// dock, those running apps are gathered into its tile instead of standing on the bar. The disk is reached only through the three
    /// closures (and `key`'s symlink resolution), for the tests.
    nonisolated static func items(
        pinned: [String], hidden: [String], stacks: [String], running: [RunningApp], recent: [String],
        minimized: [MinimizedWindow], widgetOrder: [String], enabledWidgets: Set<String>, edge: DockEdge,
        anchors: [String: String] = [:],
        fileExists: (String) -> Bool, isFolder: (String) -> Bool, displayName: (String) -> String
    ) -> [DockItem] {
        var runningByID: [String: RunningApp] = [:]
        for app in running {
            if let url = app.bundleURL { runningByID[key(url)] = app }
        }

        var result: [DockItem] = []
        // Hidden apps start out "seen", so both loops below skip them, pinned or running.
        var seen = Set(hidden.map { key(URL(fileURLWithPath: $0)) })
        seen.remove(finderID)
        // Finder is first unless it has been moved, which writes it into the pinned list.
        let namesFinder = pinned.contains { !$0.hasPrefix(spacerPrefix) && key(URL(fileURLWithPath: $0)) == finderID }
        for path in namesFinder ? pinned : [finderPath] + pinned {
            if path.hasPrefix(spacerPrefix) {
                result.append(DockItem(id: path, kind: .spacer, url: nil, name: "", isPinned: true, isRunning: false, pid: nil))
                continue
            }
            let url = URL(fileURLWithPath: path)
            let id = key(url)
            guard !seen.contains(id), fileExists(path) else { continue }
            seen.insert(id)
            let app = runningByID[id]
            result.append(DockItem(
                id: id, kind: .app, url: url, name: displayName(path),
                isPinned: true, isRunning: app != nil, pid: app?.pid
            ))
        }
        // Bottom only, as the widgets are: on a side dock the tile never shows, and the apps with it.
        let collects = edge == .bottom && enabledWidgets.contains("runningApps")
        var collected: [DockItem] = []
        for app in running {
            let id = app.id
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            let item = DockItem(
                id: id, kind: .app, url: app.bundleURL, name: app.name,
                isPinned: false, isRunning: true, pid: app.pid
            )
            if collects {
                collected.append(item)
            } else if let anchor = anchors[id] {
                // After the item it follows, and after any running app already placed behind it.
                var index = anchor.isEmpty ? 0 : (result.firstIndex { $0.id == anchor }.map { $0 + 1 } ?? result.count)
                while index < result.count, !result[index].isPinned { index += 1 }
                result.insert(item, at: index)
            } else {
                result.append(item)
            }
        }
        // Only apps with no tile already — pinned, running, hidden and Finder are all in `seen` by now.
        var recents: [DockItem] = []
        for path in recent where recents.count < recentAppsShown {
            let url = URL(fileURLWithPath: path)
            let id = key(url)
            guard !seen.contains(id), fileExists(path) else { continue }
            seen.insert(id)
            recents.append(DockItem(
                id: id, kind: .app, url: url, name: displayName(path), isPinned: false, isRunning: false, pid: nil))
        }
        if !recents.isEmpty {
            result.append(DockItem(
                id: "separator:recent", kind: .separator, url: nil, name: "", isPinned: true, isRunning: false, pid: nil))
            result += recents
        }
        result.append(DockItem(id: "separator", kind: .separator, url: nil, name: "", isPinned: true, isRunning: false, pid: nil))
        var seenStacks = Set<String>()
        for path in stacks {
            // Folders only, each once: a document tile is not a stack, and a repeated path would give
            // ForEach two items with one id.
            guard isFolder(path), seenStacks.insert(path).inserted else { continue }
            result.append(DockItem(
                id: "folder:" + path, kind: .folder, url: URL(fileURLWithPath: path),
                name: displayName(path), isPinned: true, isRunning: false, pid: nil
            ))
        }
        let appNames = Dictionary(running.map { ($0.pid, $0.name) }) { first, _ in first }
        for window in minimized {
            result.append(DockItem(
                id: "min:\(window.id)", kind: .minimizedWindow, url: nil, name: window.title,
                isPinned: false, isRunning: true, pid: window.pid, windowID: window.id,
                appName: appNames[window.pid].flatMap { $0.isEmpty ? nil : $0 }))
        }
        result.append(DockItem(id: "trash", kind: .trash, url: nil, name: "Trash", isPinned: true, isRunning: false, pid: nil))
        // Bottom only: the widgets are wide, short text tiles, and a side dock's bar is one icon
        // wide — they would spill across the screen or be crushed to nothing.
        // Normalized on every read, not just at load: a sync or an import can hand back an order
        // missing a widget, and a missing one would never show.
        for name in edge == .bottom ? normalizedWidgetOrder(widgetOrder) : [] {
            let kind: DockItem.Kind
            switch name {
            case "nowPlaying": kind = .nowPlaying
            case "weather": kind = .weather
            case "clock": kind = .clock
            case "battery": kind = .battery
            case "calendar": kind = .calendar
            case "runningApps": kind = .runningApps
            case "keepAwake": kind = .keepAwake
            default: continue
            }
            guard enabledWidgets.contains(name) else { continue }
            // An empty tile would be a gap that says nothing; it comes back with the first app.
            if kind == .runningApps, collected.isEmpty { continue }
            result.append(DockItem(
                id: widgetIDPrefix + name, kind: kind, url: nil, name: name, isPinned: true, isRunning: false,
                pid: nil, apps: kind == .runningApps ? collected : []))
        }
        return result
    }

    func icon(for item: DockItem) -> NSImage {
        // Read for the dependency alone: when the icon sweep drops a stale entry and bumps the
        // version, every tile asks again and the dropped ones refetch.
        _ = iconsVersion
        if item.kind == .trash {
            return NSImage(named: trashIsFull ? NSImage.trashFullName : NSImage.trashEmptyName) ?? NSImage()
        }
        if let cached = icons[item.id] { return cached }
        let icon = if item.kind == .minimizedWindow {
            // Its app's icon, which marks the tile until the window's snapshot lands.
            item.pid.flatMap { NSRunningApplication(processIdentifier: $0)?.icon } ?? NSImage()
        } else {
            item.url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage()
        }
        icons[item.id] = icon
        return icon
    }

    /// Whether the Trash holds anything, without reading it. Listing ~/.Trash needs Full Disk Access
    /// ("Operation not permitted" otherwise, so the Trash always looked empty), but `stat` on the
    /// folder and on a known name inside it does not. Measured on APFS: a folder's link count is 2
    /// plus every item in it, files and folders alike — so the count, less Finder's own `.DS_Store`,
    /// is the number of things in the Trash.
    func refreshTrash() {
        var folder = stat()
        guard stat(Self.trashURL.path, &folder) == 0 else { return }
        var items = Int(folder.st_nlink) - 2
        var dsStore = stat()
        if stat(Self.trashURL.path + "/.DS_Store", &dsStore) == 0 { items -= 1 }
        let full = items > 0
        if full != trashIsFull { trashIsFull = full }
    }

    /// Nothing announces an app's icon changing on disk — an update swaps the whole bundle, a custom
    /// icon from Get Info plants an icon file inside it — but either moves the bundle's modification
    /// date. So this stats each app tile's bundle, off the main thread in case one lives on a dead
    /// network volume, and drops the cached icon of any whose date moved since the last sweep.
    /// Apps only: a folder's date moves whenever its contents do, which would redraw the bar all day.
    /// (An icon repainted only in a running app's memory announces nothing macOS lets us hear —
    /// `NSRunningApplication.icon` is not KVO-observable — so that still shows the disk icon.)
    func refreshIcons() {
        guard !isSweepingIcons else { return }
        isSweepingIcons = true
        let paths = builtItems.flatMap { [$0] + $0.apps }.compactMap { item in
            item.kind == .app ? item.url.map { (item.id, $0.path) } : nil
        }
        let known = iconStamps
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var stamps: [String: Date] = [:]
            for (id, path) in paths {
                var info = stat()
                guard stat(path, &info) == 0 else { continue }
                stamps[id] = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                    + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isSweepingIcons = false
                    self.iconStamps = stamps
                    var dropped = false
                    for id in Self.changedIcons(old: known, new: stamps)
                    where self.icons.removeValue(forKey: id) != nil { dropped = true }
                    if dropped { self.iconsVersion += 1 }
                }
            }
        }
    }

    /// The ids whose modification date moved between sweeps. An id seen for the first time has not
    /// changed — that sweep only takes its baseline. Pure, for the tests.
    nonisolated static func changedIcons(old: [String: Date], new: [String: Date]) -> Set<String> {
        Set(new.filter { id, date in old[id].map { $0 != date } ?? false }.map(\.key))
    }

    // MARK: - Actions

    func open(_ item: DockItem) {
        var launchStart: Date?
        switch item.kind {
        case .app:
            if let app = runningApp(item) {
                bringForward(app)
                restoreMinimizedWindow(of: app)
            } else if let url = item.url {
                // Bounce from the click, not from macOS's "will launch", which can lag a moment
                // behind while Launch Services finds the app.
                launchStart = startedLaunching(url, byClick: true)
            }
            if let url = item.url {
                let launchStart = launchStart
                // Launches it if it is not running. If it is, this sends the reopen event, which
                // brings back a window when it has none — what a Dock click does; activating alone
                // would leave a windowless app frontmost with nothing to show.
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) {
                    [weak self] _, error in
                    // A launch that failed would bounce the full timeout. Only one that began a
                    // bounce: a reopen of a running app has none to stop. Launch Services shows its
                    // own alert for most failures, so this only logs.
                    guard let error, let start = launchStart else { return }
                    NSLog("DockPlus: could not open \(url.lastPathComponent): \(error)")
                    Task { @MainActor in self?.stopBouncing(Self.key(url), startedAt: start) }
                }
            }
        case .folder:
            if let url = item.url { showStack(url) }
        case .trash:
            NSWorkspace.shared.open(Self.trashURL)
        case .minimizedWindow:
            if let windowID = item.windowID, let pid = item.pid {
                WindowActions.raise(windowID, pid: pid)
            }
        case .separator, .spacer, .nowPlaying, .weather, .clock, .battery, .calendar, .runningApps, .keepAwake:
            break
        }
    }

    /// Since macOS 14, activation is cooperative: an app can only hand the focus to another while it
    /// holds the focus itself, and a click in DockPlus's non-activating panel deliberately never gives
    /// it the focus. So a bare request to activate the clicked app was a request macOS was free to
    /// ignore — and for some apps it did, leaving them behind. Taking the focus for a moment and then
    /// yielding it to the app is the handover the system honours.
    private func bringForward(_ app: NSRunningApplication) {
        NSApp.activate(ignoringOtherApps: true)
        if app.isHidden { app.unhide() }
        // All windows, as a Dock click does — not just the app's key window.
        app.activate(from: .current, options: [.activateAllWindows])
    }

    /// When every window the app has is minimized, puts the frontmost one back — as a Dock click does.
    /// Activating alone brings the app forward with nothing to show, and the reopen event sent after
    /// this only restores a window in apps that choose to handle it; many do not, which is why some
    /// minimized apps stayed minimized.
    ///
    /// Needs Accessibility permission: another app's windows are only reachable through AX. The
    /// system prompt is shown the first time it is needed in each run — here or closing a window from a
    /// preview — not on every click; after that the permission is only checked, and this is skipped
    /// until it is granted.
    private func restoreMinimizedWindow(of app: NSRunningApplication) {
        guard WindowActions.requestAccessibilityOnce(),
              let windows = WindowActions.windows(of: app.processIdentifier)
        else { return }
        // Standard windows only: panels, sheets and palettes do not count as something to show.
        let standard = windows.filter {
            WindowActions.string(of: $0, kAXSubroleAttribute) == kAXStandardWindowSubrole
        }
        guard !standard.isEmpty, standard.allSatisfy(WindowActions.isMinimized), let window = standard.first else {
            return
        }
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    /// A click that relaunches while the earlier launch is still counted gets a fresh start and
    /// timeout, so the earlier launch's pending stop (see `stopBouncing`) cannot end the new bounce.
    /// macOS's "will launch" for an app already counted is the click's own launch arriving late: it
    /// keeps the click's start, which a failed launch's stop is matched against.
    @discardableResult
    private func startedLaunching(_ url: URL, byClick: Bool = false) -> Date? {
        let id = Self.key(url)
        guard launching.insert(id).inserted || byClick else { return nil }
        let start = Date()
        launchStarts[id] = start
        // Ends the launch, not the bounce: each icon rests at the end of its own cycle (see DockIcon).
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchTimeout) { [weak self] in
            MainActor.assumeIsolated { self?.stopBouncing(id, startedAt: start) }
        }
        return start
    }

    /// Ends the launch once it has run one whole cycle from its start, so every icon has been shown
    /// at least one bounce. An icon that is mid-cycle then finishes it on its own: the docks on
    /// several displays are revealed at different moments, so no single stop lands on all their
    /// cycle boundaries.
    private func finishedLaunching(_ url: URL) {
        let id = Self.key(url)
        guard let start = launchStarts[id] else { return }
        let remaining = Self.bounceRemaining(after: Date().timeIntervalSince(start))
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
            MainActor.assumeIsolated { self?.stopBouncing(id, startedAt: start) }
        }
    }

    /// How long a bounce `elapsed` seconds in has left until its cycle ends — at least one whole
    /// cycle from the start. Pure, for the tests.
    nonisolated static func bounceRemaining(after elapsed: TimeInterval) -> TimeInterval {
        let cycles = max((elapsed / bounceCycle).rounded(.up), 1)
        return cycles * bounceCycle - elapsed
    }

    /// How long an icon whose launch just ended, and whose current bounce began at `start`, keeps
    /// bouncing to finish that cycle. Zero when it is not drawn (`isShown` false: the dock is hidden
    /// or bouncing is off) or never began. Never more than one cycle: the wall clock can step back
    /// between `start` and `now`, and the step must not be bounced out. Pure, for the tests.
    nonisolated static func bounceRestDelay(startedAt start: Date?, now: Date, isShown: Bool) -> TimeInterval {
        guard isShown, let start else { return 0 }
        return min(bounceRemaining(after: now.timeIntervalSince(start)), bounceCycle)
    }

    /// Only when this is still the launch it was scheduled for: a quit and relaunch inside the
    /// timeout must not have its bounce cut short by the earlier launch's timer.
    private func stopBouncing(_ id: String, startedAt start: Date) {
        guard launchStarts[id] == start else { return }
        launchStarts[id] = nil
        launching.remove(id)
    }

    enum ClickAction: Equatable { case open, reveal, openHidingOthers, hide }

    /// What a click on an item does. Command reveals it in Finder and Option opens an app while
    /// hiding the rest, as in the macOS Dock; with the setting on, a click on the app already in
    /// front hides it. Pure, for the tests.
    nonisolated static func clickAction(
        kind: DockItem.Kind, hasURL: Bool, command: Bool, option: Bool, isFrontmost: Bool,
        hidesFrontmost: Bool
    ) -> ClickAction {
        if command, hasURL, kind == .app || kind == .folder { return .reveal }
        guard kind == .app else { return .open }
        if option { return .openHidingOthers }
        if hidesFrontmost, isFrontmost { return .hide }
        return .open
    }

    /// A click on an icon, with the modifier keys held for it. VoiceOver's press passes none: its
    /// own keys include Option, which would otherwise read as an Option-click and hide every app.
    func click(_ item: DockItem, modifiers: NSEvent.ModifierFlags) {
        let app = runningApp(item)
        let isFrontmost = app != nil
            && app?.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier
        let action = Self.clickAction(
            kind: item.kind, hasURL: item.url != nil, command: modifiers.contains(.command),
            option: modifiers.contains(.option), isFrontmost: isFrontmost,
            hidesFrontmost: settings.clickHidesFrontmostApp)
        switch action {
        case .open: if !openAsGrid(item) { open(item) }
        case .reveal: reveal(item)
        case .hide: app?.hide()
        case .openHidingOthers:
            open(item)
            hideOthers(than: item)
        }
    }

    /// Every other app hidden. Not `NSApp.hideOtherApplications`: that spares the app calling it —
    /// DockPlus — and so would hide the very app just clicked. An app still launching has no pid yet,
    /// so everything else hides and it opens onto a clear screen.
    private func hideOthers(than item: DockItem) {
        let me = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != me
            && app.processIdentifier != item.pid && !app.isHidden {
            app.hide()
        }
    }

    func hide(_ item: DockItem) { runningApp(item)?.hide() }
    func unhide(_ item: DockItem) { runningApp(item)?.unhide() }

    /// Unhidden and in front with every window, without the reopen event a click sends — that
    /// could open a new window in an app that has none, which is not what this asks for.
    func showAllWindows(_ item: DockItem) {
        if let app = runningApp(item) { bringForward(app) }
    }

    func quit(_ item: DockItem) { runningApp(item)?.terminate() }
    func forceQuit(_ item: DockItem) { runningApp(item)?.forceTerminate() }

    func reveal(_ item: DockItem) {
        if let url = item.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func pin(_ item: DockItem) {
        if let url = item.url { place(url.path, before: nil) }
    }

    /// Keeps the app out of the dock for good, running or not — and so out of the pinned list too.
    func hideFromDock(_ item: DockItem) {
        guard item.kind == .app, item.id != Self.finderID, let url = item.url else { return }
        if !settings.hiddenApps.contains(where: { Self.key(URL(fileURLWithPath: $0)) == item.id }) {
            settings.hiddenApps.append(url.path)
        }
        settings.pinnedApps.removeAll { Self.key(URL(fileURLWithPath: $0)) == item.id }
    }

    func unpin(_ item: DockItem) {
        switch item.kind {
        case .app:
            settings.pinnedApps.removeAll { Self.key(URL(fileURLWithPath: $0)) == item.id }
        case .folder:
            settings.stacks.removeAll { "folder:" + $0 == item.id }
        case .spacer:
            settings.pinnedApps.removeAll { $0 == item.id }
        case .trash, .separator, .minimizedWindow, .nowPlaying, .weather, .clock, .battery, .calendar, .runningApps,
             .keepAwake:
            return
        }
    }

    // MARK: - Recent apps

    /// As many as the macOS Dock shows.
    nonisolated static let recentAppsShown = 3
    /// More kept than shown: an app on the list that is pinned or running again since has a tile
    /// already and is skipped, and the next one down takes its place rather than leaving a gap.
    nonisolated static let recentAppsKept = 10

    /// Recorded at the quit, not the launch: while an app runs it has a running tile anyway, so
    /// quitting is the moment it becomes recent. Only an app that had a tile of its own on the bar
    /// — not a hidden one, a helper or DockPlus's own osascript children — and not Finder, which is
    /// always there. Off, nothing is recorded, so turning the switch on starts an empty list rather
    /// than one kept behind the user's back.
    private func recordQuit(_ url: URL) {
        guard settings.showsRecentApps else { return }
        let id = Self.key(url)
        // The running-apps tile's apps had tiles too, just gathered into one.
        let tiles = items.flatMap { $0.kind == .runningApps ? $0.apps : [$0] }
        // Not a pinned one: `items()` never lists it as recent, so it would only take a slot.
        guard id != Self.finderID,
              tiles.contains(where: { $0.id == id && $0.kind == .app && $0.isRunning && !$0.isPinned })
        else { return }
        let updated = Self.recordingRecent(url.path, in: settings.recentApps)
        if updated != settings.recentApps { settings.recentApps = updated }
    }

    /// The recent list once the app at `path` has quit: first, once (compared after symlinks
    /// resolve, as the bar compares apps), and no more than `recentAppsKept`. Pure, for the tests.
    nonisolated static func recordingRecent(_ path: String, in list: [String]) -> [String] {
        let id = key(URL(fileURLWithPath: path))
        return Array(([path] + list.filter { key(URL(fileURLWithPath: $0)) != id }).prefix(recentAppsKept))
    }

    func addSpacer(divider: Bool = false) {
        settings.addSpacer(divider: divider)
    }

    func emptyTrash() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"Finder\" to empty trash"]
        let err = Pipe()
        process.standardError = err
        process.terminationHandler = { [weak self] process in
            // Only a refusal (-1743) is a permission problem. Cancelling Finder's "are you sure?"
            // (-128) is the user's answer, and any other failure is not something Automation fixes —
            // both used to bring up the permission alert all the same.
            let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let denied = process.terminationStatus != 0 && message.contains("-1743")
            if process.terminationStatus != 0, !denied, !message.contains("-128") {
                NSLog("DockPlus: emptying the Trash failed: \(message)")
            }
            Task { @MainActor in
                self?.refreshTrash()
                if denied { DockModel.explainAutomationDenied() }
            }
        }
        do {
            try process.run()
        } catch {
            NSLog("DockPlus: could not run osascript to empty the Trash: \(error)")
        }
    }

    /// osascript fails when DockPlus is not allowed to control Finder, and otherwise nothing would say so.
    private static func explainAutomationDenied() {
        let alert = NSAlert()
        alert.messageText = "DockPlus couldn't empty the Trash"
        alert.informativeText = """
            DockPlus needs permission to control Finder. Turn on Finder under DockPlus in \
            System Settings › Privacy & Security › Automation.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        // DockPlus is a background app; without this the alert can open behind other windows.
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.openPrivacyPane("Automation")
    }

    // MARK: - Helpers

    private static let trashURL = URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")

    /// Paths compare after symlinks resolve: a bundle URL and a pinned path can name the same app
    /// through different routes.
    nonisolated static func key(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func runningApp(_ item: DockItem) -> NSRunningApplication? {
        item.pid.flatMap { NSRunningApplication(processIdentifier: $0) }
    }
}

extension DockModel.RunningApp {
    init(_ app: NSRunningApplication) {
        self.init(pid: app.processIdentifier, bundleURL: app.bundleURL, name: app.localizedName ?? "")
    }
}

extension NSWorkspace {
    /// System Settings on a Privacy & Security pane, named by what follows "Privacy_" — the one
    /// URL scheme every permission hint in the app sends people to.
    func openPrivacyPane(_ name: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_" + name)
        else { return }
        open(url)
    }
}

/// An NSMenuItem that runs a closure, since the model is not an NSObject to be a target.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, image: NSImage? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        self.image = image
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { handler() }
}
