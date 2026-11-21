import AppKit
import ApplicationServices
import ScreenCaptureKit
import os

/// One window's preview: enough to draw the thumbnail and to act on the window afterwards.
/// `CGImage` is immutable; the conformance is stated because the SDK does not.
struct WindowThumb: Identifiable, @unchecked Sendable {
    let id: CGWindowID
    let title: String
    /// Where the window is, in window-server coordinates (y down from the primary display's top).
    let frame: CGRect
    let image: CGImage
    /// Pixels per point in `image`: drawn at this scale, it keeps its size in points on any display.
    let scale: CGFloat
}

/// One-shot thumbnails of an app's windows — ScreenCaptureKit screenshots, never a stream. ScreenCaptureKit rather than Accessibility decides
/// which windows exist: AX returns an empty list for Chromium and Electron apps (measured there).
enum WindowCapture {
    @MainActor private static var hasAskedForPermission = false

    /// Previews need Screen Recording. Asks the system once per run, the first time a preview would
    /// appear; after that the panel shows a pointer to System Settings instead.
    @MainActor static var canCapture: Bool { CGPreflightScreenCaptureAccess() }

    @MainActor static func askForPermissionOnce() {
        guard !hasAskedForPermission, !canCapture else { return }
        hasAskedForPermission = true
        CGRequestScreenCaptureAccess()
    }

    /// Front-to-back thumbnails of `pid`'s windows, at most `maxHeight` points tall, `scale` pixels to
    /// the point — the display's backing scale, or a Retina panel showed them upscaled and soft.
    /// Empty when the app has no windows or every capture came up blank. Nil when the window list
    /// could not be read, or every capture that was tried failed — permission revoked, say — so the
    /// caller does not take a failure for a real empty answer.
    nonisolated static func thumbnails(pid: pid_t, maxHeight: CGFloat, scale: CGFloat) async -> [WindowThumb]? {
        // Cancelled between steps: the pointer sweeping along the bar with the panel up cancels a
        // capture per icon passed, and each ran to the end regardless — a window list, an AX query
        // and up to ten screenshots nobody would see.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        } catch {
            return failed(error, "window list", pid: pid)
        }
        guard !Task.isCancelled else { return [] }
        // The title filter is the one that matters: layer-0 debris — Chrome's dropdown surfaces,
        // Electron overlays — is untitled. `onScreenWindowsOnly: false` keeps windows on other
        // Spaces and minimized ones, which capture real pixels (measured: 15–60 ms each).
        let axClaimed = axWindowIDs(pid: pid)
        let windows = content.windows.filter { window in
            guard window.owningApplication?.processID == pid, window.windowLayer == 0,
                window.windowID != 0, window.frame.width > 40, window.frame.height > 40,
                !(window.title ?? "").isEmpty
            else { return false }
            // Titled, full-size phantoms remain — Teams keeps an 800×600 shell window that shows
            // as a strip of buttons (measured 2026-09-28). A real window is on screen, or on some
            // Desktop, or claimed by its app through AX; the shell is none of the three. AX alone
            // cannot decide it: Electron apps claim no windows at all.
            return window.isOnScreen || isOnSomeSpace(window.windowID) || axClaimed.contains(window.windowID)
        }.prefix(10)
        guard !Task.isCancelled else { return [] }
        let (thumbs, failures) = await captureAll(Array(windows), maxHeight: maxHeight, scale: scale)
        return thumbs.isEmpty && failures > 0 && !Task.isCancelled ? nil : thumbs
    }

    /// Logs a ScreenCaptureKit error and answers nil. Cancellation is routine — the pointer sweeping
    /// along the bar cancels a capture per icon passed — and is neither logged nor a failure. Logged
    /// once per app and error: an app whose windows can never be captured fails on every hover.
    private nonisolated static func failed(_ error: Error, _ what: String, pid: pid_t) -> [WindowThumb]? {
        if Task.isCancelled || error is CancellationError { return [] }
        let key = "\(pid) \(what) \((error as NSError).domain) \((error as NSError).code)"
        if loggedFailures.withLock({ $0.insert(key).inserted }) {
            NSLog("DockPlus: preview \(what) failed for pid \(pid): \(error)")
        }
        return nil
    }

    private nonisolated static let loggedFailures = OSAllocatedUnfairLock(initialState: Set<String>())

    /// Several windows by id from one enumeration of the window list — the minimized-window tiles,
    /// where a sweep can turn up several at once and each alone cost a full `SCShareableContent`
    /// round trip. Windows that are gone, or capture blank, are left out.
    nonisolated static func windowThumbnails(ids: [CGWindowID], maxHeight: CGFloat) async -> [WindowThumb] {
        guard !ids.isEmpty,
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        else { return [] }
        let wanted = Set(ids)
        return await captureAll(
            content.windows.filter { wanted.contains($0.windowID) }, maxHeight: maxHeight, scale: 1
        ).thumbs
    }

    /// In parallel, but back in the order given — front-to-back, for a pid's windows. A blank capture
    /// is no picture and is left out, which keeps a minimized tile on its app-icon fallback.
    private nonisolated static func captureAll(
        _ windows: [SCWindow], maxHeight: CGFloat, scale: CGFloat
    ) async -> (thumbs: [WindowThumb], failures: Int) {
        // SCWindow is not Sendable; the wrapper only carries it into the child task.
        struct Job: @unchecked Sendable {
            let index: Int
            let window: SCWindow
        }
        let jobs = windows.enumerated().map { Job(index: $0.offset, window: $0.element) }
        // A nil thumb with `failed` set is an error; without it, a blank capture or a cancellation.
        let results: [(index: Int, thumb: WindowThumb?, failed: Bool)] = await withTaskGroup(
            of: (index: Int, thumb: WindowThumb?, failed: Bool).self
        ) { group in
            for job in jobs {
                group.addTask {
                    guard !Task.isCancelled else { return (job.index, nil, false) }
                    do {
                        let image = try await capture(job.window, maxHeight: maxHeight, scale: scale)
                        guard !isBlank(image) else { return (job.index, nil, false) }
                        return (job.index, WindowThumb(
                            id: job.window.windowID, title: job.window.title ?? "", frame: job.window.frame,
                            image: image, scale: scale), false)
                    } catch {
                        let isFailure = failed(
                            error, "capture", pid: job.window.owningApplication?.processID ?? 0) == nil
                        return (job.index, nil, isFailure)
                    }
                }
            }
            var out: [(index: Int, thumb: WindowThumb?, failed: Bool)] = []
            for await result in group { out.append(result) }
            return out
        }
        let thumbs = results.sorted { $0.index < $1.index }.compactMap(\.thumb)
        return (thumbs, results.filter(\.failed).count)
    }

    private typealias SetCurrentSpaceFn = @convention(c) (Int32, CFString, UInt64) -> Void
    private typealias ShowHideSpacesFn = @convention(c) (Int32, CFArray) -> Void
    private static let setCurrentSpace = SkyLight.symbol("CGSManagedDisplaySetCurrentSpace", SetCurrentSpaceFn.self)
    private static let showSpaces = SkyLight.symbol("CGSShowSpaces", ShowHideSpacesFn.self)
    private static let hideSpaces = SkyLight.symbol("CGSHideSpaces", ShowHideSpacesFn.self)

    private nonisolated static func spaceID(from dict: [String: Any]) -> UInt64? {
        ((dict["ManagedSpaceID"] as? NSNumber) ?? (dict["id64"] as? NSNumber))?.uint64Value
    }

    /// A Desktop change one display has to make to show a window.
    struct SpaceTrip {
        let display: String
        let destination: UInt64
        let origin: UInt64
    }

    /// The change that would show `windowID`, on whichever display its Desktop belongs to. nil when
    /// a display already shows it, or the layout cannot be read.
    nonisolated static func trip(toSpaceOf windowID: CGWindowID) -> SpaceTrip? {
        guard let mainConnection = SkyLight.mainConnection,
              let copySpacesForWindows = SkyLight.copySpacesForWindows,
              let spaces = copySpacesForWindows(
                mainConnection(), SkyLight.allSpacesMask, [NSNumber(value: windowID)] as CFArray)?
                .takeRetainedValue() as? [NSNumber]
        else { return nil }
        // Every Space the window is on, not just the first: a window assigned to All Desktops is on
        // all of them, the list starts at Desktop 1, and switching there would yank the user away
        // from a Desktop that already shows it.
        let windowSpaces = Set(spaces.map(\.uint64Value))
        for display in SkyLight.managedDisplays() {
            guard let ident = display["Display Identifier"] as? String,
                  let list = display["Spaces"] as? [[String: Any]],
                  let windowSpace = list.lazy.compactMap(spaceID(from:)).first(where: windowSpaces.contains),
                  let current = (display["Current Space"] as? [String: Any]).flatMap(spaceID(from:))
            else { continue }
            if windowSpaces.contains(current) { return nil }
            return SpaceTrip(display: ident, destination: windowSpace, origin: current)
        }
        return nil
    }

    /// Whether `trip`'s display now shows its destination.
    nonisolated static func hasArrived(_ trip: SpaceTrip) -> Bool {
        SkyLight.managedDisplays().contains { display in
            display["Display Identifier"] as? String == trip.display
                && (display["Current Space"] as? [String: Any]).flatMap(spaceID(from:)) == trip.destination
        }
    }

    /// Switches to the Desktop holding `windowID` without the Dock, for when the Dock will not
    /// travel: `WindowActions.raise` asks it first. `CGSManagedDisplaySetCurrentSpace` re-points the
    /// window server's bookkeeping and the screen keeps compositing the Desktop it came from, so the
    /// window looks like it jumped to that Desktop and goes back on the next real transition.
    /// Pairing the write with CGSShowSpaces/CGSHideSpaces does not prevent that (measured on macOS
    /// 27.2: the old Desktop stayed up for minutes).
    @discardableResult
    nonisolated static func travelToSpace(of windowID: CGWindowID) -> Bool {
        guard let mainConnection = SkyLight.mainConnection, let setCurrentSpace, let showSpaces, let hideSpaces,
              let trip = trip(toSpaceOf: windowID)
        else { return false }
        let cid = mainConnection()
        showSpaces(cid, [NSNumber(value: trip.destination)] as CFArray)
        setCurrentSpace(cid, trip.display as CFString, trip.destination)
        hideSpaces(cid, [NSNumber(value: trip.origin)] as CFArray)
        return true
    }

    /// Whether the window server has the window on any Desktop.
    /// Unreadable counts as "yes": better a phantom thumbnail than real windows vanishing.
    nonisolated static func isOnSomeSpace(_ windowID: CGWindowID) -> Bool {
        guard let mainConnection = SkyLight.mainConnection,
              let copySpacesForWindows = SkyLight.copySpacesForWindows else { return true }
        guard let spaces = copySpacesForWindows(
            mainConnection(), SkyLight.allSpacesMask, [NSNumber(value: windowID)] as CFArray)?.takeRetainedValue()
        else { return true }
        return CFArrayGetCount(spaces) > 0
    }

    /// The windows the app itself lists over Accessibility. Empty for Electron apps — and when the
    /// permission is missing — so membership can only ever rescue a window, never veto one.
    private nonisolated static func axWindowIDs(pid: pid_t) -> Set<CGWindowID> {
        Set((WindowActions.windows(of: pid) ?? []).compactMap(WindowActions.windowID(of:)))
    }

    /// Captured straight at thumbnail size rather than scaled afterwards.
    private nonisolated static func capture(_ window: SCWindow, maxHeight: CGFloat, scale: CGFloat) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let pixelsPerPoint = min(1, maxHeight / max(window.frame.height, 1)) * scale
        config.width = max(Int(window.frame.width * pixelsPerPoint), 1)
        config.height = max(Int(window.frame.height * pixelsPerPoint), 1)
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Whether a capture is a transparent nothing — helper surfaces capture fully clear. Sampled on
    /// a 16×16 grid; blank means fewer than a tenth of the samples carry any alpha.
    private nonisolated static func isBlank(_ image: CGImage) -> Bool {
        let side = 16
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return false }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var opaque = 0
        for i in 0..<(side * side) where pixels[i * 4 + 3] > 8 { opaque += 1 }
        return opaque < side * side / 10
    }
}

/// Acting on one specific window, which only Accessibility can do. Needs the same permission the
/// minimized-window restore already asks for; without it, raising falls back to activating the app.
@MainActor
enum WindowActions {
    /// The only bridge from a CGWindowID to an AX element. Private but long-stable; loaded once,
    /// and nil simply downgrades every raise to an app activation.
    typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    /// Shared with WindowCapture's claims check; the symbol only needs loading once.
    nonisolated static let getWindowIDFn: GetWindowFn? = {
        guard let handle = dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
            let symbol = dlsym(handle, "_AXUIElementGetWindow")
        else { return nil }
        return unsafeBitCast(symbol, to: GetWindowFn.self)
    }()

    /// An app's windows as it lists them over Accessibility; nil when it will not say. AX calls block
    /// until the app answers, and a hung app would hold the caller for the default six seconds — so
    /// 0.3 s, which every caller here wants.
    nonisolated static func windows(of pid: pid_t) -> [AXUIElement]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? [AXUIElement]
    }

    /// The window server's id for an AX window; nil when the bridge is missing or it will not say.
    nonisolated static func windowID(of window: AXUIElement) -> CGWindowID? {
        guard let getWindowIDFn else { return nil }
        var id: CGWindowID = 0
        guard getWindowIDFn(window, &id) == .success, id != 0 else { return nil }
        return id
    }

    nonisolated static func isMinimized(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success else {
            return false
        }
        return (value as? Bool) == true
    }

    nonisolated static func string(of element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    nonisolated static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success
        else { return [] }
        return value as? [AXUIElement] ?? []
    }

    /// Whether the Accessibility prompt has been shown in this run — one flag for every caller, so a
    /// restore from the dock and a close from a preview never prompt twice.
    private static var hasPromptedForAccessibility = false

    /// Whether DockPlus may use Accessibility. The system prompt is shown the first time this is asked
    /// in each run, not on every click; after that the permission is only checked.
    static func requestAccessibilityOnce() -> Bool {
        guard !hasPromptedForAccessibility else { return AXIsProcessTrusted() }
        hasPromptedForAccessibility = true
        // The option's key as a literal: the exported `kAXTrustedCheckOptionPrompt` is a mutable
        // global, which Swift 6 will not read from here.
        return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    private typealias SetFrontFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> OSStatus
    private typealias PostEventFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> OSStatus
    private typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    private static let setFront = SkyLight.symbol("_SLPSSetFrontProcessWithOptions", SetFrontFn.self)
    private static let postEvent = SkyLight.symbol("SLPSPostEventRecordTo", PostEventFn.self)
    /// By path, not from the loaded images: importing ApplicationServices does not bring in the
    /// image that vends `GetProcessForPID` (measured), leaving the whole path silently dead.
    private static let getProcessForPID: GetProcessForPIDFn? = {
        guard let handle = dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
            let sym = dlsym(handle, "GetProcessForPID")
        else { return nil }
        return unsafeBitCast(sym, to: GetProcessForPIDFn.self)
    }()

    /// Brings one window forward. Activating the app is not enough here: an app with another window
    /// already visible — say on the second display — keeps focus on that one and never travels, which
    /// was exactly the reported failure. So this fronts the *window* through the window server
    /// once its Desktop is showing; app-level activation is only the fallback when the private
    /// symbols are gone.
    static func raise(_ windowID: CGWindowID, pid: pid_t) {
        raiseGeneration += 1
        let generation = raiseGeneration
        let app = NSRunningApplication(processIdentifier: pid)
        let axWindow = element(for: windowID, pid: pid)
        if let axWindow {
            AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        let focusAndMark = { @MainActor () -> Bool in
            // Raised here and not before the Desktop change, so the window is never ordered front
            // on a Desktop the screen is still leaving.
            if let axWindow { AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString) }
            guard focus(windowID, pid: pid) else { return false }
            if let axWindow {
                // The app's own bookkeeping, so it draws the window active rather than dimmed.
                AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(axWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
            return true
        }
        let front = { @MainActor in
            if focusAndMark() { return }
            NSApp.activate(ignoringOtherApps: true)
            if axWindow != nil {
                app?.activate()
            } else {
                // No AX and no window server: the whole app, all windows.
                app?.activate(from: .current, options: [.activateAllWindows])
            }
        }
        guard let trip = WindowCapture.trip(toSpaceOf: windowID) else {
            front()
            return
        }
        Task {
            let travelled = await dockTravels(trip, to: windowID, pid: pid, axWindow: axWindow)
            guard generation == raiseGeneration else { return }
            if !travelled {
                NSLog("DockPlus: the Dock did not travel to window %u; switching Desktops without it", windowID)
                WindowCapture.travelToSpace(of: windowID)
            }
            front()
            // Again after a Desktop switch, not only during it: key events posted mid-transition are
            // swallowed — measured here, Chrome kept its other display's window focused until the
            // focus was retried once the switch had landed.
            try? await Task.sleep(for: .milliseconds(450))
            guard generation == raiseGeneration else { return }
            _ = focusAndMark()
        }
    }

    /// Counts raises. A raise that waits on a Desktop change checks this before it touches the
    /// window, so one the user has already replaced cannot pull them back.
    private static var raiseGeneration = 0

    /// Long enough for the Dock to arrive: 380 to 444ms after it is asked, measured on macOS 27.2.
    private static let travelWait: Duration = .milliseconds(560)

    /// Has the Dock switch to the window's Desktop itself, which redraws the screen where
    /// `WindowCapture.travelToSpace` does not. Activating the app is enough when it has nothing in
    /// view. Otherwise, and for Finder, the window's entry in the app's Window menu is pressed: the
    /// app orders the window front and the Dock follows. False when neither moved the display.
    private static func dockTravels(
        _ trip: WindowCapture.SpaceTrip, to windowID: CGWindowID, pid: pid_t, axWindow: AXUIElement?
    ) async -> Bool {
        let app = NSRunningApplication(processIdentifier: pid)
        let arrived = { WindowCapture.hasArrived(trip) }
        if let inView = windowInView(of: pid, besides: windowID) {
            // By window: activating an app that has a window in view never travels, and can pull
            // the window being raised onto this Desktop instead.
            _ = focus(inView, pid: pid)
        } else {
            app?.activate()
            if travelsOnActivation(app), await waits(upTo: travelWait, until: arrived) { return true }
        }
        guard let item = windowMenuItem(for: windowID, pid: pid, axWindow: axWindow) else { return false }
        // The press is refused until the app is the active one, a few event-loop turns after the
        // window server accepts the front.
        _ = await waits(upTo: .milliseconds(300)) {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        }
        // The reply waits on the app ordering its window front, which the 0.3s the reads get can cut short.
        AXUIElementSetMessagingTimeout(item, 1)
        guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else { return false }
        return await waits(upTo: travelWait, until: arrived)
    }

    /// Whether `condition` came true within `limit`, asked every 20ms.
    private static func waits(upTo limit: Duration, until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// Whether macOS switches Desktops when `app` is activated with nothing in view. Mission
    /// Control's "When switching to an application, switch to a Space with open windows" decides
    /// it, and Finder does not travel even then (measured on macOS 27.2).
    private static func travelsOnActivation(_ app: NSRunningApplication?) -> Bool {
        let follows = CFPreferencesCopyAppValue("workspaces-auto-swoosh" as CFString, "com.apple.dock" as CFString)
        return (follows as? Bool ?? true) && app?.bundleIdentifier != "com.apple.finder"
    }

    /// The frontmost window of `pid` on screen now, leaving out `windowID`; nil when it has none.
    private static func windowInView(of pid: pid_t, besides windowID: CGWindowID) -> CGWindowID? {
        let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return onScreen.lazy
            .filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
            .first { $0 != windowID }
    }

    /// The window's entry in its app's Window menu, found by title because the item names its window
    /// by nothing else. nil when the menu lists no such window or Accessibility is not granted.
    private static func windowMenuItem(for windowID: CGWindowID, pid: pid_t, axWindow: AXUIElement?) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]]
        let serverTitle = (info?.first?[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard let title = serverTitle ?? axWindow.flatMap({ string(of: $0, kAXTitleAttribute) })
        else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar) == .success,
              let bar = bar.map({ $0 as! AXUIElement })
        else { return nil }
        // AppKit sets this action on every item it adds to a windows menu, whatever the menu is called.
        let items = children(of: bar).flatMap(children(of:)).flatMap(children(of:))
            .filter { string(of: $0, kAXIdentifierAttribute) == "makeKeyAndOrderFront:" }
        let titles = items.map { string(of: $0, kAXTitleAttribute) ?? "" }
        return windowMenuIndex(forTitle: title, in: titles).map { items[$0] }
    }

    /// Which of a Window menu's item titles names the window titled `title`. Two windows with one
    /// title match the first, which is still a window of the right app on the right Desktop.
    nonisolated static func windowMenuIndex(forTitle title: String, in itemTitles: [String]) -> Int? {
        let wanted = normalizedTitle(title)
        guard !wanted.isEmpty else { return nil }
        return itemTitles.firstIndex { normalizedTitle($0) == wanted }
    }

    /// A title without its leading decoration and case. The window server and the menu read the
    /// same title a moment apart, and a terminal's spinner glyph or an editor's unsaved dot can
    /// change in between.
    private nonisolated static func normalizedTitle(_ title: String) -> String {
        var rest = Substring(title)
        while let first = rest.first, !first.isLetter, !first.isNumber { rest = rest.dropFirst() }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Fronts `window` and sends it the key-state events a real click would have. Without the two
    /// events, apps that track key state themselves draw the window focused-but-dimmed.
    private static func focus(_ windowID: CGWindowID, pid: pid_t) -> Bool {
        guard let setFront, let postEvent, let getProcessForPID else { return false }
        var psn = ProcessSerialNumber()
        guard getProcessForPID(pid, &psn) == noErr else { return false }
        // 0x200 is `kCPSUserGenerated` — anything else is not treated as a real activation.
        guard setFront(&psn, windowID, 0x200) == noErr else { return false }
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: windowID.littleEndian) { raw in
            for (offset, byte) in raw.enumerated() { bytes[0x3c + offset] = byte }
        }
        for index in 0x20..<0x30 { bytes[index] = 0xff }
        bytes[0x08] = 0x01  // window is becoming key
        _ = postEvent(&psn, &bytes)
        bytes[0x08] = 0x02  // and is now key
        _ = postEvent(&psn, &bytes)
        return true
    }

    /// Presses the window's own close button — closing is the window's decision, not a kill.
    static func close(_ windowID: CGWindowID, pid: pid_t) {
        guard let window = element(for: windowID, pid: pid) else {
            // The close button is only reachable over Accessibility. Without it the click would do
            // nothing and say nothing, so ask for it — once per run, shared with DockModel's restore.
            if !AXIsProcessTrusted() { _ = requestAccessibilityOnce() }
            return
        }
        var button: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &button) == .success,
              let button = button.map({ $0 as! AXUIElement })
        else { return }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
    }

    private static func element(for windowID: CGWindowID, pid: pid_t) -> AXUIElement? {
        guard AXIsProcessTrusted(), Self.getWindowIDFn != nil, let windows = windows(of: pid) else { return nil }
        return windows.first { Self.windowID(of: $0) == windowID }
    }
}
