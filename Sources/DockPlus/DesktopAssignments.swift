import AppKit

/// The macOS Dock's Options ▸ Assign To: which Desktop (Space) an app's windows open on.
///
/// macOS keeps the answer in `com.apple.spaces` under `app-bindings` — lowercased bundle identifier
/// to Space UUID, `AllSpaces` for All Desktops, and no entry for None. An empty string is not All
/// Desktops: it is the UUID of the one Desktop that has none, and the Dock ticks that Desktop for it
/// (measured 2026-09-30 on macOS 27.2: Finder and GitHub Desktop, bound "", ticked Desktop 4 — the
/// Desktop with the empty UUID — in the Dock's own menu).
///
/// A choice is made by picking the same item in the hidden macOS Dock's own menu, over
/// Accessibility: the Dock owns Spaces, and only it moves the app's open windows at once. Writing
/// the dictionary and restarting the Dock only reached windows opened afterwards (measured: Teams
/// saved as All Desktops stayed on one Desktop). The Dock's menu is on screen for the moment it
/// takes, about 130 ms. What that menu does not list — a Desktop the app's windows are on that is not
/// in front — is written and the Dock restarted instead; its windows are already there to keep.
@MainActor
enum DesktopAssignments {
    enum Assignment: Equatable, Sendable {
        case none
        case allDesktops
        /// One Desktop, by its Space UUID — empty for the Desktop that has none.
        case desktop(String)
    }

    /// One display's Desktops, as the window server lists them.
    struct Display: Equatable, Sendable {
        /// The Desktop in front on it.
        let current: String?
        /// Its user Desktops' UUIDs, in the order they are numbered.
        let desktops: [String]
    }

    /// A Desktop item in the menu, ticked when `assignment` is the app's.
    struct Option: Equatable, Sendable {
        let title: String
        let assignment: Assignment
        var isEnabled = true
    }

    private nonisolated static let domain = "com.apple.spaces"
    private nonisolated static let key = "app-bindings"
    private nonisolated static let allSpaces = "AllSpaces"

    nonisolated static func assignment(of bundleID: String) -> Assignment {
        guard let uuid = bindings()[bundleID.lowercased()] else { return .none }
        return uuid == allSpaces ? .allDesktops : .desktop(uuid)
    }

    /// The Desktop items between All Desktops and None, read from the Space layout now. `pid` is the
    /// app's while it runs, for the Desktops its windows are on.
    static func desktopOptions(for current: Assignment, pid: pid_t?) -> [Option] {
        desktopOptions(displays: Spaces.displays(), current: current,
                       appDesktops: pid.map(Spaces.desktops(ofWindowsOf:)) ?? [])
    }

    /// On each display, the Desktops the app's windows are on (`appDesktops`), so assigning it keeps
    /// it where it already is; with none there, the Desktop in front, as the macOS Dock offers. The one
    /// in front is "This Desktop" with one display and "Desktop on Display 2" with several; any other
    /// goes by its number there. After them, when the app is bound to another of that display's
    /// Desktops, that one. A binding to a Desktop that no longer exists shows as Another Desktop,
    /// ticked and inert, so the tick is not lost. Several displays means "Displays have separate
    /// Spaces" is on; with it off the window server lists one.
    ///
    /// A Desktop can carry an empty UUID — Desktop 4 of this machine's display does — and is offered
    /// like any other: the Dock saves "" for it and honours that. With no Desktop known to be in
    /// front, none is offered for that display. Pure, for the tests.
    nonisolated static func desktopOptions(
        displays: [Display], current: Assignment, appDesktops: Set<String> = []
    ) -> [Option] {
        let several = displays.count > 1
        var options: [Option] = []
        var listed = Set<String>()
        for (index, display) in displays.enumerated() {
            let suffix = several ? " on Display \(index + 1)" : ""
            let frontTitle = several ? "Desktop" + suffix : "This Desktop"
            let front = display.current
            let appHere = display.desktops.filter { appDesktops.contains($0) }
            if appHere.isEmpty, let front {
                options.append(Option(title: frontTitle, assignment: .desktop(front)))
                listed.insert(front)
            }
            for (number, uuid) in display.desktops.enumerated() where appHere.contains(uuid) {
                options.append(Option(title: uuid == front ? frontTitle : "Desktop \(number + 1)" + suffix,
                                      assignment: .desktop(uuid)))
                listed.insert(uuid)
            }
            if case .desktop(let bound) = current, !listed.contains(bound),
               let number = display.desktops.firstIndex(of: bound) {
                options.append(Option(title: "Desktop \(number + 1)" + suffix, assignment: current))
                listed.insert(bound)
            }
        }
        if case .desktop(let bound) = current, !listed.contains(bound) {
            options.append(Option(title: "Another Desktop", assignment: current, isEnabled: false))
        }
        return options
    }

    /// Picks `title` for the app at `app` in the Dock's menu, or writes `target` when the Dock's menu
    /// has no such item — or has one that, pressed, did not save `target`. Off the main thread: the
    /// Dock's menu takes a moment to open.
    static func assign(_ bundleID: String, to target: Assignment, title: String, app: URL) {
        guard AXIsProcessTrusted() else {
            write(bundleID, target)
            return
        }
        pressQueue.async {
            // Looked up here, not at the click: a pick queued behind one that restarted the Dock would
            // otherwise press a Dock that has since exited. Right after such a restart the new Dock
            // may not be listed yet, so a missing pid gets one more look a moment later — the
            // fallback below restarts the Dock all over again, which one sleep is cheaper than.
            var dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
            if dock == nil {
                usleep(300_000)
                dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
            }
            if let pid = dock?.processIdentifier,
               pressDockMenuItem(title, for: app, dockPID: pid), awaitBinding(bundleID, target) { return }
            // Sync, so the next pick waits for this one's write: queued after it instead, an earlier
            // pick's write could land after a later pick and undo it.
            DispatchQueue.main.sync { MainActor.assumeIsolated { write(bundleID, target) } }
        }
    }

    /// One pick at a time: two menus of the Dock's open at once would each close the other.
    private nonisolated static let pressQueue = DispatchQueue(label: "dev.kennyb.dockplus.assign", qos: .userInitiated)

    /// Whether the Dock saved `target` after a press. An accepted press is not a done one: the Dock
    /// can ignore it, or a title it words the same can mean another Desktop. It saves within about
    /// 1 ms of the press (measured 2026-09-30, All Desktops, This Desktop and None alike); half a
    /// second is the margin for a busy Dock.
    private nonisolated static func awaitBinding(_ bundleID: String, _ target: Assignment) -> Bool {
        for _ in 0..<50 {
            if assignment(of: bundleID) == target { return true }
            usleep(10_000)
        }
        return false
    }

    /// Opens the Dock's menu for the app's tile and presses `title` in its Options — without opening
    /// that submenu, which the Dock does not need (measured). Closes the menu if the item is missing.
    private nonisolated static func pressDockMenuItem(_ title: String, for app: URL, dockPID: pid_t) -> Bool {
        let dock = AXUIElementCreateApplication(dockPID)
        AXUIElementSetMessagingTimeout(dock, 0.3)
        // By path: the Dock's tile URLs end in a slash, and one built from a symlinked bundle's path
        // (/Applications/Safari.app) does not, so as URLs they never matched.
        let target = DockModel.key(app)
        let tile = WindowActions.children(of: dock).lazy.flatMap(WindowActions.children(of:)).first { tile in
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(tile, kAXURLAttribute as CFString, &value) == .success
                && (value as? URL).map(DockModel.key) == target
        }
        guard let tile, AXUIElementPerformAction(tile, "AXShowMenu" as CFString) == .success else { return false }
        // Readable after 12–130 ms in every measurement; half a second before giving up.
        var menu: AXUIElement?
        for _ in 0..<50 {
            menu = WindowActions.children(of: tile).first
            if menu != nil { break }
            usleep(10_000)
        }
        guard let menu else { return false }
        // The titles are the Dock's own, so on a non-English system they are looked up in its
        // strings; failing that, Options is taken to be the one top-level item with a submenu.
        let options = Set(["Options", localizedDockTitle("Options")])
        let wanted = Set([title, localizedDockTitle(title)])
        let items = WindowActions.children(of: menu)
        let submenu = (items.first { options.contains(WindowActions.string(of: $0, kAXTitleAttribute) ?? "") }
            ?? items.first { !WindowActions.children(of: $0).isEmpty })
            .flatMap { WindowActions.children(of: $0).first }
        let item = submenu.flatMap { submenu in
            WindowActions.children(of: submenu)
                .first { wanted.contains(WindowActions.string(of: $0, kAXTitleAttribute) ?? "") }
        }
        guard let item, AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
            AXUIElementPerformAction(menu, "AXCancel" as CFString)
            return false
        }
        return true
    }

    /// `title` as the Dock words it in the user's language, from the strings of Dock.app itself. The
    /// titles DockPlus builds are the Dock's English ones; unchanged when the lookup finds nothing.
    private nonisolated static func localizedDockTitle(_ title: String) -> String {
        let keys = ["Options": "OPTIONS", "All Desktops": "ALL_DESKTOPS", "This Desktop": "THIS_DESKTOP",
                    "None": "NONE"]
        let bundle = Bundle(path: "/System/Library/CoreServices/Dock.app")
        // The language is picked here, from the user's preferences: a bundle loaded by path resolves
        // through the main bundle's languages, and DockPlus ships only English, so
        // `localizedString` answered in English whatever the system language.
        let strings: [String: String] = bundle.flatMap { bundle in
            Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: Locale.preferredLanguages)
                .first
                .flatMap { bundle.path(forResource: "DockMenus", ofType: "strings", inDirectory: nil, forLocalization: $0) }
                .flatMap { NSDictionary(contentsOfFile: $0) as? [String: String] }
        } ?? [:]
        func string(_ key: String, _ arguments: [String] = []) -> String? {
            let format = strings[key] ?? bundle?.localizedString(forKey: key, value: nil, table: "DockMenus")
            guard let format, format != key else { return nil }
            return String(format: format, arguments: arguments)
        }
        if let key = keys[title] { return string(key) ?? title }
        // "Desktop on Display 2", "Desktop 3", "Desktop 3 on Display 2".
        guard title.hasPrefix("Desktop ") else { return title }
        let parts = title.dropFirst("Desktop ".count).components(separatedBy: " on Display ")
        let localized = switch (title.hasPrefix("Desktop on Display "), parts.count) {
        case (true, _): string("DESKTOP_ON", [String(title.dropFirst("Desktop on Display ".count))])
        case (false, 1): string("OTHER_DESKTOP", parts)
        case (false, _): string("OTHER_DESKTOP_ON", parts)
        }
        return localized ?? title
    }

    /// The fallback: the dictionary written and the Dock restarted to read it.
    private static func write(_ bundleID: String, _ target: Assignment) {
        let before = bindings()
        var all = before
        let id = bundleID.lowercased()
        switch target {
        case .none:
            all.removeValue(forKey: id)
        case .allDesktops:
            all[id] = allSpaces
        case .desktop(let uuid):
            all[id] = uuid
        }
        // Nothing changed, so there is nothing for the Dock to reread; restarting it would only flash.
        guard all != before else { return }
        CFPreferencesSetAppValue(key as CFString, all as CFDictionary, domain as CFString)
        CFPreferencesAppSynchronize(domain as CFString)
        SystemDock.restartDock()
    }

    private nonisolated static func bindings() -> [String: String] {
        CFPreferencesAppSynchronize(domain as CFString)
        return CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? [String: String] ?? [:]
    }
}

/// The window server's Space layout, through private SkyLight calls — there is no public API for
/// which Desktop is in front, or for the UUIDs bindings are keyed by.
@MainActor
private enum Spaces {
    /// Each display's Desktops, in the window server's display order. One entry, "Main", when
    /// "Displays have separate Spaces" is off: then every display shares one list. Full-screen apps'
    /// Spaces are left out — they are not Desktops, and are not counted in the numbering.
    static func displays() -> [DesktopAssignments.Display] {
        SkyLight.managedDisplays().map { display in
            let spaces = display["Spaces"] as? [[String: Any]] ?? []
            // A full-screen app in front makes its own Space current, which is not a Desktop and
            // would be offered as one; no current Desktop means none is offered.
            let current = display["Current Space"] as? [String: Any]
            return DesktopAssignments.Display(
                current: (current?["type"] as? Int) == 0 ? current?["uuid"] as? String : nil,
                desktops: spaces.filter { ($0["type"] as? Int) == 0 }.compactMap { $0["uuid"] as? String })
        }
    }

    /// The Desktops the app's windows are on. Every window the app has, on any Desktop — the window
    /// list's "all" option, which needs no Screen Recording for ids and owners. A window on more than
    /// one Space is one shown on every Desktop, and names none of them, so it is left out.
    static func desktops(ofWindowsOf pid: pid_t) -> Set<String> {
        guard let mainConnection = SkyLight.mainConnection,
              let spacesForWindows = SkyLight.copySpacesForWindows,
              let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return [] }
        let uuids = Dictionary(
            SkyLight.managedDisplays().flatMap { $0["Spaces"] as? [[String: Any]] ?? [] }.compactMap { space in
                (space["ManagedSpaceID"] as? Int).flatMap { id in (space["uuid"] as? String).map { (id, $0) } }
            },
            uniquingKeysWith: { first, _ in first })
        let connection = mainConnection()
        var found = Set<String>()
        for window in info where (window[kCGWindowOwnerPID as String] as? pid_t) == pid
            && (window[kCGWindowLayer as String] as? Int) == 0 {
            guard let id = window[kCGWindowNumber as String] as? UInt32,
                  let spaces = spacesForWindows(connection, SkyLight.allSpacesMask, [NSNumber(value: id)] as CFArray)?
                    .takeRetainedValue() as? [Int],
                  spaces.count == 1, let uuid = uuids[spaces[0]]
            else { continue }
            found.insert(uuid)
        }
        return found
    }
}
