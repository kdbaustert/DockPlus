import AppKit
import ServiceManagement
import Sparkle

@main
@MainActor
enum DockPlusApp {
    static func main() {
        let app = NSApplication.shared
        // NSApp holds its delegate weakly; this local lives as long as `run()`, which never returns.
        let delegate = AppDelegate()
        app.delegate = delegate
        // In code, not `LSUIElement` in Info.plist: with that key, macOS still took the menu bar
        // away while Settings had switched the app to `.regular`. Set before `run()`, so no Dock
        // icon appears at launch either way.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = DockSettings.shared
    private var model: DockModel?
    private var controllers: [DockController] = []
    private var menuBarItem: MenuBarItem?
    private var settingsSync: SettingsSync?
    private var watchdog: Timer?
    private var pendingRebuild: DispatchWorkItem?
    /// Why the dock is out of sight, by the notification that said so. Paused while any is.
    private var pauseReasons: Set<Notification.Name> = []
    private var isPaused: Bool { !pauseReasons.isEmpty }
    /// Answers Sparkle's "which channels?" before each check. Held here because Sparkle keeps only
    /// a weak reference to its delegate.
    private let updateChannels = UpdateChannels()
    /// nil in a build with no feed (every plain `build.sh` build), where an updater could only fail.
    private var updater: SPUStandardUpdaterController?
    /// Held so the sources stay armed; see `installSignalHandlers`.
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = DockModel(settings: settings)
        self.model = model
        rebuildControllers()
        // From the dock on the pointer's display, which is the one clicked; the first dock for a
        // VoiceOver press with the pointer elsewhere. One grid at a time across every dock.
        model.showStackGrid = { [weak self] item in
            guard let controllers = self?.controllers,
                  let target = controllers.first(where: { $0.ownsPointer }) ?? controllers.first
            else { return false }
            for controller in controllers where controller !== target { controller.closeStackGrid() }
            target.toggleStackGrid(item)
            return true
        }
        // Both what decides which screens get a dock: the setting, and the screens themselves.
        observeContinuously(ownedBy: self) { [settings] in
            _ = (settings.displayMode, settings.specificDisplay)
        } onChange: { [weak self] in
            self?.rebuildControllers()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRebuild() }
        }
        // `startingUpdater: true` starts the scheduled daily check (SUEnableAutomaticChecks).
        if Updater.isConfigured {
            updater = SPUStandardUpdaterController(
                startingUpdater: true, updaterDelegate: updateChannels, userDriverDelegate: nil)
        }
        menuBarItem = MenuBarItem(settings: settings, updater: updater)
        settingsSync = SettingsSync(settings: settings)
        // Before the hide: a kill during its waits otherwise took the default action, mid-change.
        installSignalHandlers()
        if settings.hidesSystemDock {
            SystemDock.hide()
        } else {
            // A restore whose writes failed keeps the saved originals (they are the only copy);
            // finish it now. A no-op when nothing is saved.
            SystemDock.restore()
        }
        startWatchdog()
        observeContinuously(ownedBy: self) { [settings] in
            _ = settings.hidesSystemDock
        } onChange: { [weak self] in
            self?.startWatchdog()
        }
        observeSleep()
    }

    /// The Dock's preferences are not DockPlus's to keep. Something else rewrote them within an hour
    /// of the first install — the delay vanished and the Dock slid up at the screen edge again —
    /// so hiding once at launch is not enough. The check is two preference reads; the Dock is
    /// only touched when they are wrong. Only while DockPlus hides the Dock at all: with the setting
    /// off, it woke every three seconds to read a flag.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
        guard settings.hidesSystemDock, !isPaused else { return }
        let watchdog = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.settings.hidesSystemDock == true { SystemDock.hide() }
            }
        }
        watchdog.tolerance = 1
        RunLoop.main.add(watchdog, forMode: .common)
        self.watchdog = watchdog
    }

    /// `killall DockPlus`, Activity Monitor's Quit and a shutdown running late all arrive as bare
    /// signals: the process exits with no delegate callback (SIGTERM measured: status 143), and the
    /// macOS Dock stayed hidden with nothing left to bring it back. Dispatch sources rather than
    /// `signal` handlers, which may only call async-signal-safe functions — a restore runs
    /// `defaults` and `killall`. Restored even with the login item on, unlike the system-quit path in
    /// `applicationShouldTerminate`: a logout quits through that path, so a signal is nearly always
    /// mid-session, and skipping the restore left the rest of the session with no dock at all. SIGUSR1
    /// is the one exit that keeps the Dock hidden: `build.sh --install` sends it, so the copy it
    /// launches next finds nothing to change rather than restarting the Dock a second time. SIGKILL
    /// and real crashes cannot be caught; after those the saved originals survive, and the next launch
    /// resumes hiding from them or finishes the restore.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP, SIGUSR1] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    if sig != SIGUSR1, let self, self.settings.hidesSystemDock {
                        // The watchdog would re-hide the Dock from inside the restore, whose waits
                        // spin the run loop.
                        self.watchdog?.invalidate()
                        SystemDock.restore()
                    }
                    exit(128 + sig)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// With the display asleep, or another user's session in front after a fast user switch, no one
    /// can see the dock, and every timer DockPlus has went on waking the Mac for it all night: the
    /// pointer poll, the model's two-second beat and the watchdog. Each pair's second notification
    /// undoes its first; the two can overlap — a display that sleeps behind a switched-away session
    /// — so the dock wakes only when neither holds.
    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        let pairs: [(pause: Notification.Name, resume: Notification.Name)] = [
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification),
            (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification),
        ]
        for (pause, resume) in pairs {
            center.addObserver(forName: pause, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setPaused(true, because: pause) }
            }
            center.addObserver(forName: resume, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setPaused(false, because: pause) }
            }
        }
    }

    private func setPaused(_ paused: Bool, because reason: Notification.Name) {
        let wasPaused = isPaused
        if paused { pauseReasons.insert(reason) } else { pauseReasons.remove(reason) }
        guard isPaused != wasPaused else { return }
        model?.setPaused(isPaused)
        for controller in controllers { controller.setPaused(isPaused) }
        if isPaused {
            watchdog?.invalidate()
            watchdog = nil
        } else {
            // Whatever rewrote the Dock's preferences may have done it while the dock slept.
            if settings.hidesSystemDock { SystemDock.hide() }
            startWatchdog()
        }
    }

    /// Waking a Mac posts a burst of screen-parameter notifications, and each rebuilt every panel.
    private func scheduleRebuild() {
        pendingRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.rebuildControllers() }
        }
        pendingRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// One dock per screen the display mode names. Rebuilt whole on any change: controllers are
    /// cheap, and reconciling panels across display setups is exactly the bookkeeping that breeds
    /// stale frames.
    private func rebuildControllers() {
        guard let model else { return }
        for controller in controllers { controller.tearDown() }
        let screens = NSScreen.screens
        guard let first = screens.first else {
            controllers = []
            return
        }
        let targets: [NSScreen] = switch settings.displayMode {
        case .all: screens
        case .specific: [screens.first { $0.displayUUID == settings.specificDisplay } ?? first]
        case .followPointer, .primary: [first]
        }
        controllers = targets.map { DockController(model: model, settings: settings, screen: $0) }
        // Displays come and go around sleep; a dock built while paused starts paused.
        if isPaused {
            for controller in controllers { controller.setPaused(true) }
        }
    }

    /// Opening DockPlus again while it runs — Finder, Spotlight, Launchpad — shows Settings: with no
    /// window and possibly no menu-bar icon, there is otherwise nothing to show that it heard.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.show()
        return false
    }

    /// Asks whether to bring the macOS Dock back. Not at logout or shutdown: nobody is there to
    /// answer. Then it is restored without asking, unless DockPlus starts at login — only then does
    /// something hide the Dock again, and restoring would just flash it at the next login. Without
    /// the login item, keeping it hidden left the next session with no dock at all. Nor for an
    /// update's relaunch: the new copy starts at once and hides the Dock again from the saved
    /// originals, which stay in place.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard settings.hidesSystemDock, !updateChannels.isRelaunchingForUpdate else { return .terminateNow }
        if Self.isSystemQuit() {
            if SMAppService.mainApp.status != .enabled {
                watchdog?.invalidate()
                SystemDock.restore()
            }
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "Restore the macOS Dock?"
        alert.informativeText = """
            If you keep it hidden, you will have no dock until DockPlus is opened again.
            """
        alert.addButton(withTitle: "Restore Dock")
        alert.addButton(withTitle: "Keep Hidden")
        alert.addButton(withTitle: "Cancel")
        // The blunt form: DockPlus is a background app with nothing frontmost, and the polite
        // `activate()` can be declined, leaving the alert behind other apps' windows.
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // The watchdog would re-hide the Dock from inside the restore, whose waits spin the run loop.
            watchdog?.invalidate()
            SystemDock.restore()
            return .terminateNow
        case .alertSecondButtonReturn:
            // The saved originals stay in place, so a later quit can still restore them.
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    /// Whether this quit is a logout, restart or shutdown — read from the quit event itself rather
    /// than remembered from a power-off notification, which stays set if the logout is cancelled.
    private static func isSystemQuit() -> Bool {
        guard let reason = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.typeCodeValue
        else { return false }
        let systemReasons = [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart,
                             kAEShowShutdownDialog, kAEShutDown]
        return systemReasons.contains(reason)
    }
}
