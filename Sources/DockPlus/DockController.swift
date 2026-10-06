import AppKit
import SwiftUI

/// Owns the panel along the screen edge and decides, from the pointer, what the dock does:
/// magnify, take clicks, auto-hide.
///
/// The panel spans the whole edge and is deep enough for magnified icons and their name labels, so
/// most of it is transparent. It ignores the mouse except while the pointer is over the bar, which
/// lets clicks through to the windows behind everywhere else.
@MainActor
final class DockController {
    private static let labelRoom: CGFloat = 40
    private static let sideLabelRoom: CGFloat = 240

    private let model: DockModel
    private let settings: DockSettings
    let state = PanelState()
    private let panel = DockPanel()
    private let previews: PreviewController
    private let grid = StackGridController()
    /// The item under the pointer at the last tick, for the grid: a click on its own stack's icon
    /// must reach the icon rather than close the grid on the way.
    private var hoveredItemID: String?
    /// The display this dock is anchored to, by id: an NSScreen instance goes stale across
    /// configuration changes, an id names the display for as long as it is attached.
    private var displayID: CGDirectDisplayID
    private var timer: Timer?
    private var isPollingFast = false
    private var leftBarAt: Date?
    private var edgeHeldAt: Date?
    private var openMenus = 0
    /// Kept so tearDown can remove them: block observers outlive their controller otherwise, and
    /// every display change would leave two more behind.
    private var observers: [NSObjectProtocol] = []
    /// The event monitors that stand in for the timer while the pointer rests away from the edge.
    private var monitors: [Any] = []
    private var lastMouse: NSPoint?
    private var stillTicks = 0
    /// When the button came up during a drag from the bar, and whether that was clear of it; see
    /// `trackDrag`.
    private var dragRelease: (at: Date, away: Bool)?
    /// Display asleep or another user's session in front: nothing to see, so nothing runs.
    private var isPaused = false
    /// Whether another app's window reaches into the resting bar, as last checked; only consulted
    /// with "only when a window overlaps" on. See `refreshOverlap`.
    private var isOverlapped = false
    private var overlapTimer: Timer?
    /// The beat that watches for Mission Control while the panel is on screen; see `refreshMissionControl`.
    private var missionControlTimer: Timer?
    /// Whether the panel is hidden because Mission Control (or Exposé) is up. The real Dock, still
    /// running under DockPlus, draws its own bar over Mission Control whatever its auto-hide says,
    /// and DockPlus's panel would otherwise show beneath it.
    private var hiddenForMissionControl = false
    /// On NSWorkspace's own centre, so kept apart from `observers` for removal.
    private var workspaceObservers: [NSObjectProtocol] = []
    /// False while the panel's Space is not in front — a full-screen app's, where the panel, as the
    /// real Dock, does not appear. Cached, not asked per tick: the ticks run at display rate.
    private var isOnActiveSpace = true

    /// Nil while no screen is attached at all — display sleep or an unplug on a headless-capable Mac
    /// empties the list, and indexing it then would trap.
    private var screen: NSScreen? {
        NSScreen.screens.first { $0.displayID == displayID } ?? NSScreen.screens.first
    }

    init(model: DockModel, settings: DockSettings, screen: NSScreen) {
        self.model = model
        self.settings = settings
        displayID = screen.displayID
        previews = PreviewController(settings: settings)

        let host = FirstMouseHostingView(rootView: DockView(model: model, state: state, settings: settings))
        // The panel's frame is DockPlus's to set; without this the hosting view resizes the window to
        // fit its content.
        host.sizingOptions = []
        panel.contentView = host
        layoutPanel()
        panel.orderFrontRegardless()

        grid.keepsOpen = { [weak self] event in
            guard let self else { return false }
            return event.type == .leftMouseDown && event.window === panel && hoveredItemID == grid.itemID
        }
        // The grid keeps the dock up without ticks (see `canIdle`), so an idle poll has to be woken
        // for the hide countdown to start once it is gone. Only an idle one: restarting a running
        // poll would drop it to the slow rate under a pointer that is on the bar.
        grid.onClose = { [weak self] in
            if self?.timer == nil { self?.setPolling(fast: false) }
        }

        // No observer for screen changes: AppDelegate replaces every controller on one, and a layout
        // here first was work thrown away a moment later.
        let center = NotificationCenter.default
        // An open context menu or stack keeps the dock up even though the pointer has left the bar,
        // and takes the preview down: the two would otherwise sit on top of each other.
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.openMenus += 1
                self?.previews.hide()
                self?.refreshMenuWindows()
            }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.openMenus = max((self?.openMenus ?? 1) - 1, 0) }
        })
        // A window comes to the front or goes with its app, or a whole Desktop's worth changes: the
        // moments a window is most likely to have arrived on the bar or left it. Screen changes need
        // nothing here — they rebuild every controller, and a new one checks as it starts.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshActiveSpace()
                    self?.refreshOverlap()
                }
            })
        }
        trackSettings()
        setPolling(fast: false)
        updateOverlapWatch()
        updateMissionControlWatch()
        // Not left at its assumed true: controllers are rebuilt on display changes, which can land
        // while a full-screen Space is up — waking the display mid-video — and a new one would run
        // magnification and previews for a bar no one can see until the next app or Space change.
        refreshActiveSpace()
    }

    /// Ordered out and stopped; the delegate replaces controllers when the display setup changes.
    func tearDown() {
        // First: closing wakes the poll, which the lines below then stop.
        grid.close()
        timer?.invalidate()
        timer = nil
        overlapTimer?.invalidate()
        overlapTimer = nil
        missionControlTimer?.invalidate()
        missionControlTimer = nil
        disarmMonitors()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers = []
        previews.hide()
        panel.orderOut(nil)
    }

    private func trackSettings() {
        observeContinuously(ownedBy: self) { [settings] in
            _ = (settings.edge, settings.iconSize, settings.iconPadding, settings.dockPadding,
                 settings.magnifies, settings.magnifyAmount, settings.autoHides,
                 settings.autoHidesOnlyWhenOverlapped)
        } onChange: { [weak self] in
            self?.layoutPanel()
            // Before the wake below, so the tick it causes decides on this layout's overlap.
            self?.updateOverlapWatch()
            // Turning on auto-hide must hide a dock the pointer is resting away from.
            self?.setPolling(fast: false)
        }
    }

    /// Stopped outright while nobody can see the dock; see AppDelegate.
    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if paused {
            timer?.invalidate()
            timer = nil
            disarmMonitors()
            previews.hide()
            grid.close()
        } else {
            setPolling(fast: false)
        }
        updateOverlapWatch()
        updateMissionControlWatch()
    }

    /// Whether the pointer is on this dock's display — the dock a click on a stack came from.
    var ownsPointer: Bool {
        screen.map { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? false
    }

    /// A Grid stack's click: its grid over the icon, or, when that grid is already up, closed — a
    /// second click on a stack closes it, as in the macOS Dock. The anchor is worked out here from
    /// the layout the ticks read, rather than kept from the last tick: a VoiceOver press has no
    /// pointer on the icon to have been ticked.
    func toggleStackGrid(_ item: DockItem) {
        if grid.itemID == item.id {
            grid.close()
            return
        }
        guard let url = item.url, let index = model.items.firstIndex(where: { $0.id == item.id }) else { return }
        let layout = model.layout(for: state)
        previews.hide()
        let anchor = DockAnchor(
            center: layout.center(of: index), dockFrame: panel.frame, edge: settings.edge,
            barReach: barReach(layout))
        grid.show(
            item.id, folder: url, sort: settings.stackSort(for: url.path), at: anchor,
            within: screen?.visibleFrame)
    }

    func closeStackGrid() {
        grid.close()
    }

    /// The menu that just opened — the hovered item's, which is the one right-clicked — is built
    /// again, with its window list asked for afresh. SwiftUI shows a reopened menu as it built it
    /// last, and asks for the list only when it builds it, so a window closed since stayed listed.
    /// Only this item's: rebuilding every cached menu would queue an Accessibility query per app
    /// ahead of the one being opened, and re-read the login items and Spaces for each.
    private func refreshMenuWindows() {
        guard let id = hoveredItemID, let item = model.items.first(where: { $0.id == id }),
              item.kind == .app
        else { return }
        model.menuOpened(id)
        if item.isRunning, let pid = item.pid { model.requestMenuWindows(for: pid) }
    }

    private func layoutPanel() {
        guard let screen = self.screen else { return }
        let metrics = model.metrics
        let depth = metrics.magnifiedSize + 2 * metrics.padding
        // A launch bounce lifts the icon half its size above its resting place, which at large icon
        // sizes outgrows the room the name label needs.
        let extra = max(Self.labelRoom, metrics.iconSize * 0.5 + metrics.padding)
        let full = screen.frame
        // Side docks stop at the menu bar; the bottom dock owns the whole width.
        let top = screen.visibleFrame.maxY
        let frame = switch settings.edge {
        case .bottom:
            NSRect(x: full.minX, y: full.minY, width: full.width, height: depth + extra)
        case .left:
            NSRect(x: full.minX, y: full.minY, width: depth + Self.sideLabelRoom, height: top - full.minY)
        case .right:
            NSRect(x: full.maxX - depth - Self.sideLabelRoom, y: full.minY, width: depth + Self.sideLabelRoom, height: top - full.minY)
        }
        panel.setFrame(frame, display: true)
        state.stripLength = settings.edge == .bottom ? frame.width : frame.height
    }

    // MARK: - Pointer

    /// Polls the pointer rather than monitoring events. A global monitor goes quiet once the pointer
    /// is over DockPlus's own panel, a local one needs the panel to be key (it never is), and neither
    /// reliably reports a Finder drag in progress. Reading the location is cheap. Near the edge it
    /// runs at the display's refresh rate (120 Hz on ProMotion) so magnification keeps up with the
    /// pointer; the rate drops to 10 Hz whenever the pointer is away from the edge or has rested
    /// near it for `slowAfterStillTicks`, and to nothing once it has rested off the bar — see `canIdle`.
    private func setPolling(fast: Bool) {
        guard !isPaused, timer == nil || fast != isPollingFast else { return }
        disarmMonitors()
        timer?.invalidate()
        isPollingFast = fast
        // This dock's own display: with a ProMotion laptop beside a 60 Hz monitor, the first screen's
        // rate would be wrong for one of the two docks.
        let refreshRate = Double(max(screen?.maximumFramesPerSecond ?? 60, 60))
        let timer = Timer(timeInterval: fast ? 1 / refreshRate : 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = fast ? 0.002 : 0.02
        // .common, so it keeps running while a menu or a drag spins the run loop in tracking mode.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        // No screen attached: nothing to lay out against; the next display change rebuilds anyway.
        // Resolved once: `screen` searches every attached display, and this runs up to 120 times a second.
        guard let screen = self.screen else { return }
        let mouse = NSEvent.mouseLocation
        // Follow the pointer: when it crosses onto another screen, the dock goes with it.
        if settings.displayMode == .followPointer,
            let under = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
            under.displayID != displayID {
            displayID = under.displayID
            previews.hide()
            grid.close()
            layoutPanel()
            refreshActiveSpace()
            return
        }
        let frame = panel.frame
        let (along, across) = switch settings.edge {
        case .bottom: (mouse.x - frame.minX, mouse.y - frame.minY)
        case .left: (frame.maxY - mouse.y, mouse.x - frame.minX)
        case .right: (frame.maxY - mouse.y, frame.maxX - mouse.x)
        }
        let layout = model.layout(for: state)
        let metrics = layout.metrics
        let reach = barReach(layout)
        // On a full-screen app's Space the bar is not there: the pointer along the bottom of a video
        // polled at display rate, laying out and previewing a bar no one could see.
        let atEdge = along >= 0 && along <= state.stripLength && across >= -1
        // The cache can miss an update — the notifications can fire before the window server has
        // moved the panel when a full-screen Space ends, and false would then stick: a dock that
        // looks dead until the next app switch. So a pointer at the edge of a bar the cache says is
        // absent re-asks; the cost lands only on the state the re-ask is there to correct — and only
        // within the bar's reach, since a pointer along the bottom of a full-screen video is not
        // going for the dock and would otherwise pay a window-server round trip on every slow tick.
        if atEdge, !isOnActiveSpace, across <= reach { refreshActiveSpace() }
        let onEdge = isOnActiveSpace && atEdge
        let overBar = onEdge && !state.isHidden
            && along >= layout.start && along <= layout.start + layout.length && across <= reach

        // Only where the bar is: revealed anywhere along the edge, a bar the pointer is not over
        // hides again half a second later and is at once revealed again, over and over.
        let alongBar = along >= layout.start && along <= layout.start + layout.length
        updateAutoHide(onEdge: onEdge && alongBar, across: across, overBar: overBar)

        let hoveredIndex = overBar ? layout.index(at: along) : nil
        // On all displays, only the dock on the pointer's display drives the drag: the others read
        // the pointer as off their bar and closed the gap this one had just set — the icons
        // flickered apart and together, and a drop could land with no gap left to commit. In every
        // other mode this is the only controller, so it must track wherever the pointer is.
        if model.drag == nil {
            // A drop on the bar ends the drag inside the grace period, with no tick left to clear
            // the release; kept, it ended the next drag at its first tick, as released near the bar.
            dragRelease = nil
        } else if settings.displayMode != .all || NSMouseInRect(mouse, screen.frame, false) {
            trackDrag(over: hoveredIndex, along: along, awayFromBar: across > reach + metrics.iconSize)
        }
        // Nothing is hovered while an icon is carried: no preview, and no name over the gap.
        let hoveredItem = model.drag != nil ? nil
            : hoveredIndex.flatMap { $0 < model.items.count ? model.items[$0] : nil }
        hoveredItemID = hoveredItem?.id
        // The pointer still rests on the icon while its menu is open; without this the dwell runs
        // out under the menu and the preview comes straight back. A stack's grid stands where the
        // preview would, so the same goes for it.
        if openMenus == 0, !grid.isShown {
            previews.update(
                hovered: hoveredItem, center: hoveredIndex.map(layout.center(of:)), mouse: mouse,
                dockFrame: frame, edge: settings.edge, barReach: reach, isDockHidden: state.isHidden,
                screen: screen)
        }

        // Approaching: near the bar but not on it yet. The gain ramps the growth in over the last
        // stretch of travel, so the bar swells to meet the pointer instead of jumping when it lands.
        // Not from inside a stack's grid, which sits in the approach zone: the bar would swell and the
        // poll run at display rate under a pointer that is using the grid, resting there or not.
        let inGrid = grid.contains(mouse)
        let approaching = settings.magnifyOnApproach && settings.magnifies && onEdge && !state.isHidden
            && alongBar && !overBar && !inGrid && across <= reach * 3
        let pointer = (overBar || approaching) ? along : nil
        if state.isOverBar != overBar { state.isOverBar = overBar }
        state.gain = overBar || !approaching ? 1 : max(0, 1 - (across - reach) / (reach * 2))
        if pointer != state.pointer {
            if pointer != nil, state.pointer == nil { model.refreshTrash() }
            // Every update is animated, not just entering and leaving. A spring retargets mid-flight
            // and keeps its velocity, so each new pointer position bends the motion already under
            // way instead of snapping to it — the icons glide after the pointer rather than stepping
            // once per tick, and a non-animated update would cut short any animation in progress.
            let spring: Animation? = if !settings.smoothHover {
                nil
            } else if pointer == nil {
                .smooth(duration: 0.3)
            } else {
                // No overshoot, settling in about a quarter second — DockFix's glide, measured by
                // jumping the pointer between icons: a third grown at 0.11 s, settled by 0.25-0.3 s.
                .smooth(duration: 0.25)
            }
            withAnimation(spring) { state.pointer = pointer }
        }
        if panel.ignoresMouseEvents == overBar { panel.ignoresMouseEvents = !overBar }

        if mouse == lastMouse { stillTicks += 1 } else { stillTicks = 0 }
        lastMouse = mouse
        // Display rate only while the pointer is moving. At rest in the band — where it sits after
        // every click on an icon — the fast poll ran forever, reading a pointer that had not moved;
        // now it drops to 10 Hz, and off the bar from there to idle. The first move back costs up
        // to one slow tick before the rate returns.
        // With approach on, the whole ramp (3 reach) animates at display rate, not just its inner half.
        let approachZone = settings.magnifyOnApproach && settings.magnifies ? reach * 3 : 0
        let nearZone = state.isHidden ? 20
            : max(metrics.magnifiedSize + 2 * metrics.padding + 40, approachZone)
        // Throughout a drag too, so a tap of Esc is not missed between slow ticks; see `trackDrag`.
        let fast = model.drag != nil
            || (onEdge && across < nearZone && !inGrid && stillTicks < Self.slowAfterStillTicks)
        if !fast, canIdle() {
            goIdle()
        } else {
            setPolling(fast: fast)
        }
    }

    // MARK: - Idle

    /// About a second at the slow rate with the pointer where it was.
    private static let idleAfterStillTicks = 10

    /// Half a second at 120 Hz, a second at 60, with the pointer where it was.
    private static let slowAfterStillTicks = 60

    /// Whether nothing is left for a tick to do until the pointer moves. At rest away from the edge
    /// the 10 Hz poll was two thirds of DockPlus's idle wakeups (about 10 of 15 a second), each one
    /// reading a pointer that had not moved. Not while a button is down — a Finder drag may be
    /// under way, and the poll is what notices it reaching the bar — nor while a hide, a reveal, a
    /// menu or a preview is still counting down on the ticks. A stack's grid is not on the list: it
    /// keeps the dock up by holding `leftBarAt` off, which needs no tick, and wakes the poll as it
    /// closes.
    private func canIdle() -> Bool {
        stillTicks >= Self.idleAfterStillTicks && NSEvent.pressedMouseButtons == 0
            && leftBarAt == nil && edgeHeldAt == nil && openMenus == 0 && !previews.isActive
            && !state.isOverBar && model.drag == nil
    }

    /// A drag from the bar: the gap follows the pointer along it. SwiftUI reports no end to a drag,
    /// only a drop, so a release anywhere else is read here — after a moment's grace, because a drop
    /// on the bar is delivered just after the button comes up, and ending the drag first would lose
    /// where it was dropped. Let go more than an icon's height clear of the bar, the item comes off
    /// the dock, as in the macOS Dock; anywhere nearer, it goes back. Where it was let go is kept
    /// from the release, not read after the grace, by which time the pointer has moved. No puff of
    /// smoke: `NSAnimationEffect` is deprecated since macOS 14, and its replacement is only a cursor.
    private func trackDrag(over index: Int?, along: CGFloat, awayFromBar: Bool) {
        // Esc cancels the drag, but the button is still held: the gap went on following the pointer,
        // and letting go clear of the bar then removed the item. Read off the keyboard's state, not
        // an event: the key goes to the app in front, which is rarely DockPlus. Cancelled, not
        // cleared: the AppKit session lives until the button comes up, and `handleDrop` must still
        // find the drag to swallow the release.
        if CGEventSource.keyState(.combinedSessionState, key: Self.escapeKey) {
            dragRelease = nil
            withAnimation(.smooth(duration: 0.25)) { model.cancelDrag() }
            return
        }
        guard NSEvent.pressedMouseButtons == 0 else {
            dragRelease = nil
            withAnimation(.smooth(duration: 0.2)) { model.moveDrag(over: index, along: along, state: state) }
            return
        }
        let release = dragRelease ?? (Date.now, awayFromBar)
        dragRelease = release
        guard Date.now.timeIntervalSince(release.at) > 0.3 else { return }
        dragRelease = nil
        withAnimation(.smooth(duration: 0.25)) {
            if !release.away || !model.endDragRemoving() { model.endDrag() }
        }
    }

    /// kVK_Escape, without importing Carbon for one constant.
    private static let escapeKey: CGKeyCode = 0x35

    /// The timer stops and the first mouse event of any kind starts it again. The monitors are
    /// removed as soon as one fires, so a moving pointer costs the 10 Hz poll, not an event per
    /// move. Global for other apps' events; local for DockPlus's own windows — Settings — which a
    /// global monitor never sees. The objection to monitors above is about the pointer over the
    /// panel, and at rest the panel ignores the mouse, so events go to whatever is beneath it.
    private func goIdle() {
        timer?.invalidate()
        timer = nil
        stillTicks = 0
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDown, .leftMouseDragged, .rightMouseDown, .rightMouseDragged,
            .otherMouseDown, .otherMouseDragged, .scrollWheel,
        ]
        // A tick at once, not at the first slow one: idle now happens beside the bar too, and a
        // pointer moving onto it from there would wait a tenth of a second for magnification.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.wake() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.wake() }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func wake() {
        setPolling(fast: false)
        guard timer != nil else { return }
        tick()
    }

    private func disarmMonitors() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
    }

    /// Auto-hide in force right now. With "only when a window overlaps", a dock nothing overlaps
    /// behaves exactly as with auto-hide off, and an overlapped one exactly as with it on.
    private var autoHidesNow: Bool {
        settings.autoHides && (!settings.autoHidesOnlyWhenOverlapped || isOverlapped)
    }

    private func updateAutoHide(onEdge: Bool, across: CGFloat, overBar: Bool) {
        guard autoHidesNow else {
            if state.isHidden { setHidden(false) }
            // A countdown left running when the overlap cleared kept `canIdle` false for good, and
            // hid the dock with no delay the next time a window covered it.
            leftBarAt = nil
            edgeHeldAt = nil
            return
        }
        if state.isHidden {
            // Pushing against the edge, within the sensitivity, for the reveal delay.
            if onEdge && across <= max(settings.revealSensitivity, 1) {
                if let held = edgeHeldAt {
                    if Date().timeIntervalSince(held) >= settings.revealDelay { setHidden(false) }
                } else {
                    edgeHeldAt = Date()
                }
            } else {
                edgeHeldAt = nil
            }
        } else if overBar || openMenus > 0 || previews.keepsDockShown || grid.isShown || model.drag != nil {
            leftBarAt = nil
        } else if let left = leftBarAt {
            guard Date().timeIntervalSince(left) > settings.hideDelay else { return }
            // Once per hide, not per tick: the last check can be two seconds old, and hiding for a
            // window that has since moved off the bar would only bring the dock straight back.
            refreshOverlap()
            if autoHidesNow { setHidden(true) } else { leftBarAt = nil }
        } else {
            leftBarAt = Date()
        }
    }

    /// How far the bar reaches off the edge. Once magnified, the grown icons are part of the bar;
    /// before that, only the resting bar is. Never less than the resting bar: with nothing grown —
    /// magnification off, or the pointer over widgets — depth is one padding short of the bar as
    /// drawn, and the pointer in that band read as off the bar it was visibly on: the hover state
    /// and click-through flickered at display rate, with a right-click falling through.
    private func barReach(_ layout: DockLayout) -> CGFloat {
        state.pointer == nil ? layout.metrics.thickness
            : max(layout.metrics.thickness, layout.depth + layout.metrics.padding)
    }

    private func setHidden(_ hidden: Bool) {
        leftBarAt = nil
        edgeHeldAt = nil
        // The speed settings are multipliers on the stock quarter-second-ish slide.
        let speed = max(hidden ? settings.hideSpeed : settings.revealSpeed, 0.1)
        withAnimation(.easeInOut(duration: 0.2 / speed)) { state.isHidden = hidden }
        // A slid-away bar has nothing to show through Mission Control, and a revealed one does, so
        // the watch follows the slide — see `watchesMissionControl`.
        updateMissionControlWatch()
    }

    private func refreshActiveSpace() {
        let onActiveSpace = panel.isOnActiveSpace
        guard onActiveSpace != isOnActiveSpace else { return }
        isOnActiveSpace = onActiveSpace
        // A full-screen Space has no DockPlus bar to hide, so the watch stops there and resumes when
        // an ordinary Space comes back.
        updateMissionControlWatch()
    }

    // MARK: - Overlap

    private var watchesOverlap: Bool {
        settings.autoHides && settings.autoHidesOnlyWhenOverlapped && !isPaused
    }

    /// The events above miss a window dragged or resized onto the bar while its app stays in front,
    /// so a slow beat re-checks behind them — only with the mode on and the display awake. Nothing
    /// rides on the pointer ticks: they run at display rate, and a window moving needs no such
    /// speed. Reading the on-screen window list took 0.24 ms with five windows up (measured, averaged
    /// over 200 reads).
    private func updateOverlapWatch() {
        guard watchesOverlap else {
            overlapTimer?.invalidate()
            overlapTimer = nil
            return
        }
        if overlapTimer == nil {
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshOverlap() }
            }
            // Generous, so the wakeup can fold into the model's two-second beat or the watchdog's.
            timer.tolerance = 1
            RunLoop.main.add(timer, forMode: .common)
            overlapTimer = timer
        }
        refreshOverlap()
    }

    /// Re-reads the on-screen windows. A change wakes the pointer poll if it had gone idle — its
    /// next tick hides or reveals through `updateAutoHide`, with the usual hide delay; a running
    /// poll picks the change up on its own.
    private func refreshOverlap() {
        guard watchesOverlap, let bar = restingBarFrame() else { return }
        let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let overlapped = Self.windowOverlaps(bar, windows: windows, ownPID: ProcessInfo.processInfo.processIdentifier)
        guard overlapped != isOverlapped else { return }
        isOverlapped = overlapped
        if timer == nil { setPolling(fast: false) }
    }

    /// The bar at rest, in the window server's coordinates — origin at the primary display's top
    /// left, y down — which is what window bounds come in. Nil while magnified: the layout then
    /// describes the grown bar, and with the pointer on it the dock stays up whatever overlaps.
    private func restingBarFrame() -> CGRect? {
        guard state.pointer == nil, let primary = NSScreen.screens.first else { return nil }
        let layout = model.layout(for: state)
        let thickness = layout.metrics.thickness
        let frame = panel.frame
        let bar = switch settings.edge {
        case .bottom:
            NSRect(x: frame.minX + layout.start, y: frame.minY, width: layout.length, height: thickness)
        case .left:
            NSRect(x: frame.minX, y: frame.maxY - layout.start - layout.length, width: thickness, height: layout.length)
        case .right:
            NSRect(x: frame.maxX - thickness, y: frame.maxY - layout.start - layout.length,
                   width: thickness, height: layout.length)
        }
        return CGRect(x: bar.minX, y: primary.frame.maxY - bar.maxY, width: bar.width, height: bar.height)
    }

    /// Whether another app's window reaches into `bar`; both in window-server coordinates, the
    /// windows as `CGWindowListCopyWindowInfo` describes them. Bounds need no Screen Recording, only
    /// names and titles do. Layer 0 only: the menu bar, status items, the Dock, and the desktop and
    /// its icons all sit on other layers. DockPlus's own windows never count — Settings is layer 0.
    /// Nor does a fully transparent window, which no one can see, or one that only touches the bar.
    nonisolated static func windowOverlaps(_ bar: CGRect, windows: [[String: Any]], ownPID: pid_t) -> Bool {
        windows.contains { info in
            guard info[kCGWindowLayer as String] as? Int == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? Int, pid != Int(ownPID),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary)
                      .flatMap({ CGRect(dictionaryRepresentation: $0) })
            else { return false }
            let overlap = bar.intersection(bounds)
            return !overlap.isNull && overlap.width >= 1 && overlap.height >= 1
        }
    }

    // MARK: - Mission Control

    /// Mission Control draws the real Dock over the whole screen whatever its auto-hide setting, so
    /// the moment DockPlus's panel would show beneath it is exactly while that panel is on screen:
    /// the display awake, an ordinary Space in front, and the bar not slid away. Off otherwise, the
    /// poll it drives costs nothing when there is nothing to cover.
    private var watchesMissionControl: Bool {
        !isPaused && isOnActiveSpace && !state.isHidden
    }

    /// Starts or stops the beat that catches Mission Control. No Accessibility, distributed or
    /// SkyLight notification was found to fire on a Mission Control transition (measured 2026-10-06),
    /// so a short poll of the on-screen window list is the only signal — gated to when the panel is
    /// actually on screen, per `watchesMissionControl`.
    private func updateMissionControlWatch() {
        guard watchesMissionControl else {
            missionControlTimer?.invalidate()
            missionControlTimer = nil
            // Nothing invisible left behind: a panel hidden for Mission Control when the watch stops
            // — paused, slid away, its Space gone — would never come back otherwise.
            if hiddenForMissionControl { setHiddenForMissionControl(false) }
            return
        }
        guard missionControlTimer == nil else { return }
        // About an eighth of a second: Mission Control's backdrop was readable within ~110 ms of the
        // gesture in testing, and its own fade covers the rest.
        let timer = Timer(timeInterval: 0.13, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMissionControl() }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        missionControlTimer = timer
        refreshMissionControl()
    }

    /// Reads the on-screen windows and hides or shows the panel to match Mission Control. Scoped to
    /// this dock's own display: with "Displays have separate Spaces" the backdrop is per display.
    private func refreshMissionControl() {
        guard let screen = self.screen, let primary = NSScreen.screens.first else { return }
        let frame = screen.frame
        // Window-server coordinates: origin at the primary display's top left, y down.
        let display = CGRect(
            x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let active = Self.missionControlActive(
            over: display, dockLevel: Int(CGWindowLevelForKey(.dockWindow)),
            windows: windows, ownPID: ProcessInfo.processInfo.processIdentifier)
        guard active != hiddenForMissionControl else { return }
        setHiddenForMissionControl(active)
    }

    /// Hides or shows the panel for Mission Control by its alpha, not by ordering it out: the frame
    /// and layering stay put and `isVisible` stays true, so the pointer poll and previews read the
    /// panel unchanged. Instant, with no animation — Mission Control's own fade is quick, and a slide
    /// here would trail behind it.
    private func setHiddenForMissionControl(_ hidden: Bool) {
        hiddenForMissionControl = hidden
        panel.alphaValue = hidden ? 0 : 1
    }

    /// Whether Mission Control (or Exposé) is drawing over `display`: the real Dock, auto-hidden to
    /// an edge the rest of the time, puts up a window the size of the whole display at the Dock
    /// window level while it is up. Matched by level and size, not by owner name, which needs Screen
    /// Recording. Everything in window-server coordinates. Pure, for the tests.
    nonisolated static func missionControlActive(
        over display: CGRect, dockLevel: Int, windows: [[String: Any]], ownPID: pid_t
    ) -> Bool {
        windows.contains { info in
            guard info[kCGWindowLayer as String] as? Int == dockLevel,
                  let pid = info[kCGWindowOwnerPID as String] as? Int, pid != Int(ownPID),
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary)
                      .flatMap({ CGRect(dictionaryRepresentation: $0) })
            else { return false }
            // The backdrop covers the display; the menu-bar inset keeps it a touch short of the full
            // height, so most-of-the-screen is the test, which no ordinary Dock-level window meets.
            let overlap = display.intersection(bounds)
            return !overlap.isNull && overlap.width >= display.width - 2
                && overlap.height >= display.height * 0.9
        }
    }
}

extension NSScreen {
    /// The CoreGraphics id under the AppKit wrapper — the stable name for "this display".
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    var displayUUID: String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

final class DockPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        // On every Space, still during Space switches, out of Cmd-` — and, lacking
        // .fullScreenAuxiliary, absent from full-screen apps, as the real Dock is.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        // Cmd-H while Settings is frontmost hides the whole app, which would take the dock with it.
        canHide = false
        ignoresMouseEvents = true
    }

    // Never key: clicking the dock must not take focus from the app being used.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Takes the first click even though its window is never key — otherwise every dock click would
/// only "focus" the panel and do nothing.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
