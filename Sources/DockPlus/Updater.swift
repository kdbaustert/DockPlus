import AppKit
import Sparkle

/// Updates from GitHub Releases, through Sparkle: it downloads the new version, checks its EdDSA
/// signature against `SUPublicEDKey`, and replaces the app. Each archive is an asset of its release;
/// the feed is served by GitHub Pages — see `SUFeedURL` in Info.plist and release.sh.
///
/// Wraps the controller because Settings ▸ About shows two of its facts, whether a check can start
/// and when the last one ran, and both are KVO on `SPUUpdater`, which SwiftUI cannot observe.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    /// nil when `isConfigured` is false. The About pane reaches for `shared` whatever the build, and
    /// a controller there would start a check timer in a bundle with no feed.
    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    /// Sparkle holds both delegates weakly.
    @ObservationIgnored private let channels = UpdateChannels()
    @ObservationIgnored private let reminders = UpdateReminders()
    @ObservationIgnored private var observers: [NSKeyValueObservation] = []

    /// False while a check runs, so Check Now cannot start a second one.
    private(set) var canCheck = false
    /// nil until a check has finished once.
    private(set) var lastCheck: Date?

    /// Sparkle's own preferences, read and written straight through: its timer reads them, so a copy
    /// kept here would be a second answer the schedule ignores.
    var automaticallyChecks: Bool {
        get {
            access(keyPath: \.automaticallyChecks)
            return controller?.updater.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyChecks) {
                controller?.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    /// Off by default (Info.plist): DockPlus hides the macOS Dock, and replacing itself unasked is
    /// worth a prompt.
    var automaticallyDownloads: Bool {
        get {
            access(keyPath: \.automaticallyDownloads)
            return controller?.updater.automaticallyDownloadsUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyDownloads) {
                controller?.updater.automaticallyDownloadsUpdates = newValue
            }
        }
    }

    /// Set just before Sparkle quits DockPlus to relaunch the update; see `UpdateChannels`.
    var isRelaunchingForUpdate: Bool { channels.isRelaunchingForUpdate }

    private init() {
        guard Self.isConfigured else {
            controller = nil
            return
        }
        // `startingUpdater: true` starts the scheduled daily check (SUEnableAutomaticChecks).
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: channels, userDriverDelegate: reminders)
        self.controller = controller
        canCheck = controller.updater.canCheckForUpdates
        lastCheck = controller.updater.lastUpdateCheckDate
        // On the main thread: Sparkle drives its updater from there. `lastUpdateCheckDate` is not
        // documented as KVO-compliant, so it is re-read whenever a check starts or ends instead.
        observers = [
            controller.updater.observe(\.canCheckForUpdates) { [weak self] updater, _ in
                MainActor.assumeIsolated {
                    self?.canCheck = updater.canCheckForUpdates
                    self?.lastCheck = updater.lastUpdateCheckDate
                }
            },
        ]
    }

    /// The check the user asked for, which says "you're up to date" when it finds nothing; the
    /// scheduled one stays quiet then.
    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }

    /// Catches up after an import wrote `exportedDefaultsKeys` behind Sparkle's back: the About
    /// toggles read again, and Sparkle reschedules its check, as its header asks for such a change.
    func reload() {
        guard let controller else { return }
        withMutation(keyPath: \.automaticallyChecks) {}
        withMutation(keyPath: \.automaticallyDownloads) {}
        controller.updater.resetUpdateCycleAfterShortDelay()
    }

    /// The update choices a settings export carries. Sparkle's bookkeeping (`SULastCheckTime`,
    /// `SUSkippedVersion`) describes this install, not the user's choice, and stays behind.
    nonisolated static let exportedDefaultsKeys = [
        "SUEnableAutomaticChecks",
        "SUAutomaticallyUpdate",
        UpdateChannels.betaKey,
    ]

    /// Whether this build can update itself: a release carries both a feed and a public key.
    /// `build.sh` strips the feed from local builds, so a development copy never replaces itself.
    /// Static so AppDelegate can ask before `shared` exists.
    nonisolated static var isConfigured: Bool {
        let info = Bundle.main.infoDictionary
        let feed = info?["SUFeedURL"] as? String ?? ""
        let key = info?["SUPublicEDKey"] as? String ?? ""
        return !feed.isEmpty && !key.isEmpty
    }
}

/// Which of the feed's channels this copy accepts. Stable releases carry no channel and reach
/// everyone; betas carry "beta" and are offered only when the user has opted in (a beta build is opted in until it chooses).
///
/// The preference lives in `UserDefaults` rather than on a main-actor object because Sparkle asks
/// from its own thread, and `UserDefaults` is safe to read from any.
final class UpdateChannels: NSObject, SPUUpdaterDelegate {
    nonisolated static let betaKey = "ReceiveBetaUpdates"

    /// Opt-in, except in a beta build: every release so far is one, and a beta that never offers
    /// the next beta strands its users. Answered here rather than registered as a default, so the
    /// Settings toggle and Sparkle read one answer whenever they first ask.
    static var receivesBetas: Bool {
        get {
            if let chosen = UserDefaults.standard.object(forKey: betaKey) as? Bool { return chosen }
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            return version.contains("-")
        }
        set { UserDefaults.standard.set(newValue, forKey: betaKey) }
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        Self.receivesBetas ? ["beta"] : []
    }

    /// Set just before Sparkle quits DockPlus to relaunch the update. The quit it then sends must not
    /// stop on the Restore-the-Dock dialog: nobody asked to quit, and a cancel would abort the update.
    private(set) var isRelaunchingForUpdate = false

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        isRelaunchingForUpdate = true
    }
}

/// Brings a scheduled update's alert to the front. An `.accessory` app is a background app to
/// Sparkle, and for one of those a scheduled check that finds an update shows the alert without
/// activating the app — behind whatever is frontmost. DockPlus has no tile in its own dock and no
/// Cmd-Tab entry, so nothing ever surfaced it. Claiming gentle reminders also quiets the error
/// Sparkle logs once per run about a background app that implements none. A check the user
/// started is shown in front by Sparkle itself.
final class UpdateReminders: NSObject, SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Called just before the standard driver shows the alert, on the main thread (it is AppKit UI).
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard !state.userInitiated else { return }
        // The blunt form, as the quit dialog uses: the polite `activate()` can be declined.
        MainActor.assumeIsolated { NSApp.activate(ignoringOtherApps: true) }
    }
}
