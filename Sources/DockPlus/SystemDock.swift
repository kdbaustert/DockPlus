import Foundation

/// The macOS Dock, which DockPlus hides rather than kills: the same process draws the app switcher,
/// Mission Control, Spaces and the wallpaper, so it has to stay running. Auto-hide with a delay no pointer
/// will ever wait out keeps it alive and out of sight — all but its attention bounces, which come up
/// from the screen edge regardless, and which `no-bouncing` stops unless
/// `DockSettings.systemDockBouncesForAttention` wants them.
@MainActor
enum SystemDock {
    private static let domain = "com.apple.dock"
    /// The user's own `autohide` / `autohide-delay`, captured before the first change. A key absent
    /// from the dictionary was absent from the Dock's preferences, and is deleted on restore.
    private static let savedKey = "savedSystemDock"
    /// The user's own `no-bouncing`, captured the same way. A key of its own because installs that
    /// hid the Dock before DockPlus touched `no-bouncing` already hold a `savedKey` without it, and
    /// there a missing key reads as "was absent": the restore would delete a `no-bouncing` the user
    /// had set themselves.
    private static let savedBouncingKey = "savedSystemDockBouncing"
    private static let hiddenDelay = 1000.0
    /// `restore()` waits on `defaults` and `killall`, and `waitUntilExit()` spins the main run loop
    /// while it does — so the watchdog or the Settings toggle can call `hide()` in the middle of a
    /// restore, while `hidesSystemDock` is still true, and undo it.
    private static var isRestoring = false
    /// Consecutive writes whose values never read back. Something that keeps overriding them would
    /// otherwise get a write and a Dock restart from the watchdog every few seconds, forever.
    private static var failedAttempts = 0
    private static let maxAttempts = 3

    /// What the Dock's preferences held, less DockPlus's own doing. An `autohide-delay` of
    /// `hiddenDelay` was left by a crash or Keep Hidden once DockPlus's prefs were wiped, and its
    /// `autohide` and `no-bouncing` came with it: saved as the user's, Restore Dock would write all
    /// three back.
    static func userOriginals(_ live: [String: Any]) -> [String: Any] {
        guard (live["autohide-delay"] as? Double) != hiddenDelay else { return [:] }
        return live
    }

    static func hide() {
        guard !isRestoring else { return }
        let store = UserDefaults.standard
        // Only the first time: after a crash or a kill the Dock is still hidden, and capturing it
        // again would overwrite the originals with DockPlus's own values.
        if store.dictionary(forKey: savedKey) == nil {
            let originals = userOriginals(Dictionary(
                uniqueKeysWithValues: ["autohide", "autohide-delay", "no-bouncing"].compactMap { key in
                    userValue(key).map { (key, $0) }
                }))
            store.set(originals.filter { $0.key != "no-bouncing" }, forKey: savedKey)
            if store.dictionary(forKey: savedBouncingKey) == nil {
                store.set(originals.filter { $0.key == "no-bouncing" }, forKey: savedBouncingKey)
            }
        }
        // Saved by 0.1.0-beta.1, which hid the Dock without touching `no-bouncing`: the live value
        // is still the user's own, even with DockPlus's delay in place.
        if store.dictionary(forKey: savedBouncingKey) == nil {
            var saved: [String: Any] = [:]
            if let value = userValue("no-bouncing") { saved["no-bouncing"] = value }
            store.set(saved, forKey: savedBouncingKey)
        }
        // Read fresh through CFPreferences: this runs every few seconds, and a `UserDefaults` for
        // another app's domain can go on answering from its cache after that app's prefs changed.
        CFPreferencesAppSynchronize(domain as CFString)
        let autohide = CFPreferencesCopyAppValue("autohide" as CFString, domain as CFString) as? Bool
        let delay = CFPreferencesCopyAppValue("autohide-delay" as CFString, domain as CFString) as? Double
        // Allowed to bounce, the Dock gets the user's own `no-bouncing` back, absent or not.
        let wantedNoBouncing: NSObject? = DockSettings.shared.systemDockBouncesForAttention
            ? store.dictionary(forKey: savedBouncingKey)?["no-bouncing"] as? NSObject
            : true as NSNumber
        // A forced `no-bouncing` is left as it is, rather than failing the whole hide.
        let noBouncingIsRight = CFPreferencesAppValueIsForced("no-bouncing" as CFString, domain as CFString)
            || (CFPreferencesCopyAppValue("no-bouncing" as CFString, domain as CFString) as? NSObject)
                == wantedNoBouncing
        if autohide == true, delay == hiddenDelay, noBouncingIsRight {
            failedAttempts = 0
            return
        }
        // A configuration profile that forces a key wins over any write: a forced value that is
        // already the wanted one is fine, and only the keys it leaves alone are written.
        let autohideForced = CFPreferencesAppValueIsForced("autohide" as CFString, domain as CFString)
        let delayForced = CFPreferencesAppValueIsForced("autohide-delay" as CFString, domain as CFString)
        if (autohideForced && autohide != true) || (delayForced && delay != hiddenDelay) { return }
        guard failedAttempts < maxAttempts else {
            if failedAttempts == maxAttempts {
                NSLog("DockPlus: the macOS Dock's auto-hide settings do not stick; no longer re-applying them")
                failedAttempts += 1
            }
            return
        }
        failedAttempts += 1
        if !autohideForced, autohide != true {
            defaults(["write", domain, "autohide", "-bool", "true"])
        }
        if !delayForced, delay != hiddenDelay {
            defaults(["write", domain, "autohide-delay", "-float", String(hiddenDelay)])
        }
        if !noBouncingIsRight { _ = put("no-bouncing", wantedNoBouncing) }
        run("/usr/bin/killall", ["Dock"])
    }

    /// A change the user made to a setting that decides what `hide()` wants. The mismatch it causes
    /// is not a write that failed to stick, so it starts the count over: four flips inside the
    /// watchdog's window would otherwise use up `maxAttempts` and silence the watchdog for good.
    static func settingChanged() {
        failedAttempts = 0
        hide()
    }

    static func restore() {
        // Hiding again after a restore is a fresh start, not a fourth try: three failures used to
        // stop every later hide until a relaunch.
        failedAttempts = 0
        let store = UserDefaults.standard
        let saved = store.dictionary(forKey: savedKey)
        let savedBouncing = store.dictionary(forKey: savedBouncingKey)
        guard saved != nil || savedBouncing != nil else { return }
        isRestoring = true
        defer { isRestoring = false }
        if let saved {
            var succeeded = true
            for key in ["autohide", "autohide-delay"] {
                succeeded = put(key, saved[key]) && succeeded
            }
            // Only once the Dock really has the originals back; otherwise they are the only copy left.
            if succeeded { store.removeObject(forKey: savedKey) }
        }
        if let savedBouncing, put("no-bouncing", savedBouncing["no-bouncing"]) {
            store.removeObject(forKey: savedBouncingKey)
        }
        run("/usr/bin/killall", ["Dock"])
    }

    /// A saved original written back with the type it was saved with. An untyped
    /// `defaults write com.apple.dock autohide YES` stores a string, which the Dock reads as true;
    /// restoring only a Bool deleted it, and the user's own setting was lost with the saved copy.
    /// A key that was absent when captured is deleted.
    private static func put(_ key: String, _ value: Any?) -> Bool {
        return switch value {
        case let string as String:
            defaults(["write", domain, key, "-string", string])
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            defaults(["write", domain, key, "-bool", number.boolValue ? "true" : "false"])
        case let number as NSNumber:
            defaults(["write", domain, key, CFNumberIsFloatType(number) ? "-float" : "-int", number.stringValue])
        default:
            delete(key)
        }
    }

    /// `defaults delete` exits non-zero for a key that is already absent, which is the outcome
    /// wanted — so only a key that is there counts against the restore.
    private static func delete(_ key: String) -> Bool {
        guard userValue(key) != nil else { return true }
        return defaults(["delete", domain, key])
    }

    /// The user's own value for a Dock key, which is not what `UserDefaults` or `CopyAppValue` answer
    /// when a configuration profile forces the key: those return the forced value.
    private static func userValue(_ key: String) -> Any? {
        CFPreferencesAppSynchronize(domain as CFString)
        return CFPreferencesCopyValue(
            key as CFString, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    /// File paths from one of the Dock's tile lists — `persistent-apps` (the pinned apps) or
    /// `persistent-others` (the folders beside the Trash) — used to seed DockPlus on first launch.
    static func tilePaths(_ key: String) -> [String] {
        guard let tiles = UserDefaults(suiteName: domain)?.array(forKey: key) as? [[String: Any]] else {
            return []
        }
        return tiles.compactMap { tile in
            guard let data = tile["tile-data"] as? [String: Any],
                  let file = data["file-data"] as? [String: Any],
                  let string = file["_CFURLString"] as? String
            else { return nil }
            if let url = URL(string: string), url.isFileURL { return url.path }
            return string.hasPrefix("/") ? string : nil
        }
    }

    /// Through the `defaults` tool rather than `UserDefaults(suiteName:)`: the write has to be
    /// flushed to disk before `killall Dock`, and the tool returns only once cfprefsd has it.
    @discardableResult
    private static func defaults(_ arguments: [String]) -> Bool {
        run("/usr/bin/defaults", arguments)
    }

    /// Restarts the Dock so it re-reads preferences it only loads at launch.
    static func restartDock() {
        run("/usr/bin/killall", ["Dock"])
    }

    /// Whether the tool launched and exited with status 0.
    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            NSLog("DockPlus: \(tool) failed: \(error)")
            return false
        }
    }
}
