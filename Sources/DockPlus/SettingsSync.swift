import AppKit

/// The settings that travel between Macs — in an exported file and over iCloud. Everything is
/// optional so a file from an older or newer DockPlus still applies whatever it does carry.
///
/// Some settings deliberately stay on each Mac: hiding the macOS Dock, whose change restarts that
/// Mac's Dock (not something one Mac should do to another), the sync switch itself, and everything
/// display-shaped — which screen the dock is on, and what only means something given that.
struct PortableSettings: Codable, Equatable {
    var edge: String?
    var iconSize: Double?
    var iconPadding: Double?
    var dockPadding: Double?
    var magnifies: Bool?
    var magnifyAmount: Double?
    var magnifyReach: Double?
    var magnifyOnApproach: Bool?
    /// The pre-amount schema: a magnified size in points. Read so an old file still applies.
    var magnifiedSize: Double?
    var smoothHover: Bool?
    var hoverIntensity: Double?
    var bouncesOnLaunch: Bool?
    var clickHidesFrontmostApp: Bool?
    var autoHides: Bool?
    var autoHidesOnlyWhenOverlapped: Bool?
    var revealSensitivity: Double?
    var revealDelay: Double?
    var hideDelay: Double?
    var revealSpeed: Double?
    var hideSpeed: Double?
    var showsWindowPreviews: Bool?
    var previewDelay: Double?
    var previewShowsControls: Bool?
    var livePreviews: Bool?
    var showsMinimizedWindows: Bool?
    var showsNowPlaying: Bool?
    var showsWeather: Bool?
    var showsClock: Bool?
    var showsBattery: Bool?
    var showsCalendar: Bool?
    var showsRunningApps: Bool?
    var showsKeepAwake: Bool?
    var widgetOrder: [String]?
    var weatherLocation: String?
    var weatherLatitude: Double?
    var weatherLongitude: Double?
    var weatherFahrenheit: Bool?
    var clock24Hour: Bool?
    var barTint: String?
    var barTintIntensity: Double?
    var barCornerRadius: Double?
    var iconShadows: Bool?
    var showsRunningDots: Bool?
    var showsMenuBarIcon: Bool?
    var pinnedApps: [String]?
    var stacks: [String]?
    /// Travels with `stacks`: the paths it is keyed by are the ones that list carries.
    var stackSorts: [String: String]?
    /// Keyed the same way, for the same reason.
    var stackDisplays: [String: String]?
    var hiddenApps: [String]?
    /// The switch only. The list it shows stays on each Mac; see `DockSettings.recentApps`.
    var showsRecentApps: Bool?

    /// Whether the file carried none of the settings this build knows.
    var isEmpty: Bool { self == PortableSettings() }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        // Sorted, so the same settings always produce the same bytes and an unchanged file is
        // recognisably unchanged.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decoded(from data: Data) throws -> PortableSettings {
        try JSONDecoder().decode(PortableSettings.self, from: data)
    }

    /// Whether `decoded(from:)` failed because a newer DockPlus wrote the file: a JSON object holding
    /// a setting in a type this one does not know. Bytes that are not a JSON object at all (`[]`)
    /// also fail as a type mismatch, but at the top, with an empty coding path — that file is corrupt.
    static func isFromNewerDockPlus(_ error: any Error) -> Bool {
        guard let error = error as? DecodingError, case .typeMismatch(_, let context) = error else { return false }
        return !context.codingPath.isEmpty
    }

    /// Whether the file holds a value this build cannot represent: an edge it has no case for, or a
    /// number outside its sliders' ranges. `apply` ignores the first and clamps the second, so the
    /// Mac would then differ from the file and write its degraded copy over the newer Mac's. Only a
    /// newer DockPlus produces either, so it is held like a type change; see `isFromNewerDockPlus`.
    var isBeyondThisBuild: Bool {
        if let edge, DockEdge(rawValue: edge) == nil { return true }
        return clamped() != self
    }

    /// The settings once `remote` lands on a Mac whose own are `local`, both descended from `base`:
    /// what the other Mac changed comes in, and what this one changed and has not written yet stays.
    /// Applying the whole file undid an edit made in the second before its write — the slider jumped
    /// back, and since the file was then agreed, the edit was never sent. A setting both changed
    /// takes the file's value: last writer wins, as ever. Pure, for the tests.
    static func merged(local: PortableSettings, remote: PortableSettings, base: PortableSettings) -> PortableSettings {
        func fields(_ settings: PortableSettings) -> [String: Any]? {
            (try? settings.encoded()).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        guard var out = fields(local), let theirs = fields(remote), let before = fields(base) else { return remote }
        for key in Set(theirs.keys).union(before.keys)
        where (theirs[key] as? NSObject) != (before[key] as? NSObject) {
            out[key] = theirs[key]
        }
        return (try? JSONSerialization.data(withJSONObject: out)).flatMap { try? decoded(from: $0) } ?? remote
    }

    /// Every number pulled into the range its Settings slider offers. A file is outside input: one
    /// carrying 1e20 would reach the sliders' `Int(value)` labels, which trap on it.
    func clamped() -> PortableSettings {
        func clamp(_ value: Double?, _ range: ClosedRange<Double>) -> Double? {
            value.map { min(max($0, range.lowerBound), range.upperBound) }
        }
        var p = self
        p.iconSize = clamp(iconSize, DockSettings.iconSizeRange)
        p.iconPadding = clamp(iconPadding, DockSettings.iconPaddingRange)
        p.dockPadding = clamp(dockPadding, DockSettings.dockPaddingRange)
        p.magnifyAmount = clamp(magnifyAmount, DockSettings.magnifyAmountRange)
        p.barTintIntensity = clamp(barTintIntensity, DockSettings.barTintIntensityRange)
        p.barCornerRadius = clamp(barCornerRadius, DockSettings.barCornerRadiusRange)
        p.weatherLatitude = clamp(weatherLatitude, DockSettings.weatherLatitudeRange)
        p.weatherLongitude = clamp(weatherLongitude, DockSettings.weatherLongitudeRange)
        p.magnifyReach = clamp(magnifyReach, DockSettings.magnifyReachRange)
        p.hoverIntensity = clamp(hoverIntensity, DockSettings.hoverIntensityRange)
        p.previewDelay = clamp(previewDelay, DockSettings.previewDelayRange)
        p.revealSensitivity = clamp(revealSensitivity, DockSettings.revealSensitivityRange)
        p.revealDelay = clamp(revealDelay, DockSettings.revealDelayRange)
        p.hideDelay = clamp(hideDelay, DockSettings.hideDelayRange)
        p.revealSpeed = clamp(revealSpeed, DockSettings.revealSpeedRange)
        p.hideSpeed = clamp(hideSpeed, DockSettings.hideSpeedRange)
        return p
    }
}

extension DockSettings {
    var portable: PortableSettings {
        PortableSettings(
            edge: edge.rawValue, iconSize: iconSize, iconPadding: iconPadding, dockPadding: dockPadding,
            magnifies: magnifies, magnifyAmount: magnifyAmount, magnifyReach: magnifyReach,
            magnifyOnApproach: magnifyOnApproach, smoothHover: smoothHover,
            hoverIntensity: hoverIntensity, bouncesOnLaunch: bouncesOnLaunch,
            clickHidesFrontmostApp: clickHidesFrontmostApp, autoHides: autoHides,
            autoHidesOnlyWhenOverlapped: autoHidesOnlyWhenOverlapped,
            revealSensitivity: revealSensitivity, revealDelay: revealDelay, hideDelay: hideDelay,
            revealSpeed: revealSpeed, hideSpeed: hideSpeed,
            showsWindowPreviews: showsWindowPreviews, previewDelay: previewDelay,
            previewShowsControls: previewShowsControls,
            livePreviews: livePreviews, showsMinimizedWindows: showsMinimizedWindows,
            showsNowPlaying: showsNowPlaying, showsWeather: showsWeather, showsClock: showsClock,
            showsBattery: showsBattery, showsCalendar: showsCalendar, showsRunningApps: showsRunningApps,
            showsKeepAwake: showsKeepAwake,
            widgetOrder: widgetOrder, weatherLocation: weatherLocation,
            weatherLatitude: weatherLatitude, weatherLongitude: weatherLongitude,
            weatherFahrenheit: weatherFahrenheit,
            clock24Hour: clock24Hour, barTint: barTint, barTintIntensity: barTintIntensity,
            barCornerRadius: barCornerRadius, iconShadows: iconShadows,
            showsRunningDots: showsRunningDots,
            showsMenuBarIcon: showsMenuBarIcon, pinnedApps: pinnedApps, stacks: stacks, stackSorts: stackSorts,
            stackDisplays: stackDisplays, hiddenApps: hiddenApps, showsRecentApps: showsRecentApps
        )
    }

    /// Assigns only what differs, so an unchanged value does not fire its observers (the panel would
    /// re-lay out for nothing).
    func apply(_ incoming: PortableSettings) {
        let p = incoming.clamped()
        if let v = p.edge.flatMap(DockEdge.init(rawValue:)), v != edge { edge = v }
        if let v = p.iconSize, v != iconSize { iconSize = v }
        if let v = p.iconPadding, v != iconPadding { iconPadding = v }
        if let v = p.dockPadding, v != dockPadding { dockPadding = v }
        if let v = p.magnifies, v != magnifies { magnifies = v }
        if let v = p.magnifyAmount, v != magnifyAmount { magnifyAmount = v }
        // An old export carries points; a current one carries the multiple, which wins.
        if p.magnifyAmount == nil, let v = p.magnifiedSize, iconSize > 0 {
            let amount = legacyMagnifyAmount(magnifiedSize: v, iconSize: iconSize)
            if amount != magnifyAmount { magnifyAmount = amount }
        }
        if let v = p.magnifyReach, v != magnifyReach { magnifyReach = v }
        if let v = p.magnifyOnApproach, v != magnifyOnApproach { magnifyOnApproach = v }
        if let v = p.smoothHover, v != smoothHover { smoothHover = v }
        if let v = p.hoverIntensity, v != hoverIntensity { hoverIntensity = v }
        if let v = p.bouncesOnLaunch, v != bouncesOnLaunch { bouncesOnLaunch = v }
        if let v = p.clickHidesFrontmostApp, v != clickHidesFrontmostApp { clickHidesFrontmostApp = v }
        if let v = p.autoHides, v != autoHides { autoHides = v }
        if let v = p.autoHidesOnlyWhenOverlapped, v != autoHidesOnlyWhenOverlapped { autoHidesOnlyWhenOverlapped = v }
        if let v = p.revealSensitivity, v != revealSensitivity { revealSensitivity = v }
        if let v = p.revealDelay, v != revealDelay { revealDelay = v }
        if let v = p.hideDelay, v != hideDelay { hideDelay = v }
        if let v = p.revealSpeed, v != revealSpeed { revealSpeed = v }
        if let v = p.hideSpeed, v != hideSpeed { hideSpeed = v }
        if let v = p.showsWindowPreviews, v != showsWindowPreviews { showsWindowPreviews = v }
        if let v = p.previewDelay, v != previewDelay { previewDelay = v }
        if let v = p.previewShowsControls, v != previewShowsControls { previewShowsControls = v }
        if let v = p.livePreviews, v != livePreviews { livePreviews = v }
        if let v = p.showsMinimizedWindows, v != showsMinimizedWindows { showsMinimizedWindows = v }
        if let v = p.showsNowPlaying, v != showsNowPlaying { showsNowPlaying = v }
        if let v = p.showsWeather, v != showsWeather { showsWeather = v }
        if let v = p.showsClock, v != showsClock { showsClock = v }
        if let v = p.showsBattery, v != showsBattery { showsBattery = v }
        if let v = p.showsCalendar, v != showsCalendar { showsCalendar = v }
        if let v = p.showsRunningApps, v != showsRunningApps { showsRunningApps = v }
        if let v = p.showsKeepAwake, v != showsKeepAwake { showsKeepAwake = v }
        if let v = p.widgetOrder, v != widgetOrder { widgetOrder = v }
        if let v = p.weatherLocation, v != weatherLocation { weatherLocation = v }
        if let v = p.weatherLatitude, v != weatherLatitude { weatherLatitude = v }
        if let v = p.weatherLongitude, v != weatherLongitude { weatherLongitude = v }
        if let v = p.weatherFahrenheit, v != weatherFahrenheit { weatherFahrenheit = v }
        if let v = p.clock24Hour, v != clock24Hour { clock24Hour = v }
        if let v = p.barTint, v != barTint { barTint = v }
        if let v = p.barTintIntensity, v != barTintIntensity { barTintIntensity = v }
        if let v = p.barCornerRadius, v != barCornerRadius { barCornerRadius = v }
        if let v = p.iconShadows, v != iconShadows { iconShadows = v }
        if let v = p.showsRunningDots, v != showsRunningDots { showsRunningDots = v }
        if let v = p.showsMenuBarIcon, v != showsMenuBarIcon { showsMenuBarIcon = v }
        if let v = p.pinnedApps, v != pinnedApps { pinnedApps = v }
        if let v = p.stacks, v != stacks { stacks = v }
        if let v = p.stackSorts, v != stackSorts { stackSorts = v }
        if let v = p.stackDisplays, v != stackDisplays { stackDisplays = v }
        if let v = p.hiddenApps, v != hiddenApps { hiddenApps = v }
        if let v = p.showsRecentApps, v != showsRecentApps { showsRecentApps = v }
    }
}

// MARK: - Export and import

@MainActor
enum SettingsFile {
    static func export(_ settings: DockSettings) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "DockPlus Settings.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try settings.portable.encoded().write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    static func importInto(_ settings: DockSettings) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try PortableSettings.decoded(from: Data(contentsOf: url))
            // Every field is optional, so any JSON object decodes; one with no setting in it is
            // some other file, and applying it would do nothing without saying so.
            guard !imported.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            settings.apply(imported)
        } catch {
            let alert = NSAlert()
            if PortableSettings.isFromNewerDockPlus(error) {
                alert.messageText = "That file is from a newer version of DockPlus."
                alert.informativeText = "Update DockPlus, then import it again."
            } else {
                alert.messageText = "That file isn't a DockPlus settings file."
                alert.informativeText = error.localizedDescription
            }
            alert.runModal()
        }
    }
}

// MARK: - iCloud

/// Keeps the portable settings in a file in iCloud Drive, so every Mac signed in to the same account
/// shares them: a plain file in the user's own iCloud Drive folder, which syncs
/// like any other document and needs no ubiquity entitlement — which a locally signed app cannot
/// have, so `NSUbiquitousKeyValueStore` is not an option.
///
/// Changes here are written after a short pause (a slider drag is dozens of changes); changes there
/// are noticed by watching the folder, with a slow poll behind it because iCloud does not always
/// deliver a file-system event when it swaps a download in. Last writer wins.
@MainActor
@Observable
final class SettingsSync {
    /// The running sync, for Settings to show its last error.
    private(set) static weak var current: SettingsSync?

    static var folderURL: URL? {
        let cloudDocs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: cloudDocs.path) else { return nil }
        return cloudDocs.appendingPathComponent("DockPlus", isDirectory: true)
    }

    /// False when iCloud Drive is off or signed out on this Mac.
    static var isAvailable: Bool { folderURL != nil }

    private static var fileURL: URL? { folderURL?.appendingPathComponent("settings.json") }

    /// Why the last write failed, until one succeeds; shown under the sync toggle. It used to go
    /// only to the log, so a sync that had stopped working looked exactly like one that worked.
    private(set) var lastError: String?

    @ObservationIgnored private let settings: DockSettings
    @ObservationIgnored private var isRunning = false
    /// The settings the file and this Mac last agreed on. A change that matches it — the echo of
    /// applying the file, or a file this Mac wrote itself — is not sent back round.
    ///
    /// Kept in this Mac's defaults too, not in the shared file: held only in memory, it was gone at
    /// the next launch, the merge base fell back to the settings as sync started, and the file won
    /// every field it differed on — silently undoing any edit that had not reached iCloud before
    /// the last exit.
    @ObservationIgnored private var agreed: PortableSettings? {
        didSet { Self.storeAgreed(agreed) }
    }
    private static let agreedKey = "syncAgreedSettings"

    private static func storeAgreed(_ settings: PortableSettings?) {
        guard let data = try? settings?.encoded() else {
            UserDefaults.standard.removeObject(forKey: agreedKey)
            return
        }
        UserDefaults.standard.set(data, forKey: agreedKey)
    }

    private static func loadAgreed() -> PortableSettings? {
        UserDefaults.standard.data(forKey: agreedKey).flatMap { try? PortableSettings.decoded(from: $0) }
    }
    /// This Mac's settings as sync started: what a file landing before any agreement is merged
    /// against, so an edit made while the first read was pending survives it.
    @ObservationIgnored private var startedWith: PortableSettings?
    /// When the file was first found missing, before this Mac has agreed on one; see `readRemote`.
    @ObservationIgnored private var absentSince: Date?
    /// Whether this Mac may write: only once it has adopted the file, or seen that there is none.
    /// Until then a write would put this Mac's settings over another's that simply had not
    /// downloaded yet — at a launch offline, or before iCloud had fetched the file.
    @ObservationIgnored private var mayWrite = false
    /// Until then, nothing is pushed: at launch the file on disk can be one iCloud has not refreshed
    /// yet (login is when it lags most), and a write built on it can win iCloud's conflict and make
    /// every other Mac read its own newer edits as reverted. The first push re-reads the file.
    @ObservationIgnored private var launchHoldUntil: Date?
    @ObservationIgnored private var lastModified: Date?
    /// When the copy in iCloud first failed to become current, while this Mac waits on it. A wait
    /// that lasts is reported; see `noteStall`.
    @ObservationIgnored private var stalledSince: Date?
    /// Wall-clock time the queued write is due. `asyncAfter` counts uptime, which stops in sleep,
    /// so a write queued before sleep fires late by the sleep's length; `push` spots that here.
    @ObservationIgnored private var pendingWriteDue: Date?
    @ObservationIgnored private var pendingWrite: DispatchWorkItem?
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var poll: Timer?
    @ObservationIgnored private var isFetching = false

    init(settings: DockSettings) {
        self.settings = settings
        Self.current = self
        // Only the switch is read under tracking. Starting inside `read` made everything it touched
        // a dependency — `apply` reads every portable setting, the first write encodes them all — so
        // an unrelated change re-ran start or stop. `onChange` runs on a later main-actor turn, after
        // the switch's didSet, so it sees the new value.
        observeContinuously(ownedBy: self) { [settings] in
            _ = settings.syncsWithICloud
        } onChange: { [weak self] in
            self?.followSwitch()
        }
        followSwitch()
        // Just after wake the file can still read as current while iCloud has newer on the way, so
        // the launch hold starts over and the next read looks afresh.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.holdAfterWake() }
        }
        observeContinuously(ownedBy: self) { [settings] in
            _ = settings.portable
        } onChange: { [weak self] in
            self?.scheduleWrite()
        }
    }

    private func followSwitch() {
        // The agreed baseline is forgotten only when the user turned sync off. iCloud going away
        // stops the work but keeps it, so edits made meanwhile are merged, not reverted, when it
        // returns.
        settings.syncsWithICloud && Self.isAvailable ? start() : stop(forgetAgreement: !settings.syncsWithICloud)
        // The poll lives as long as the switch is on, not as long as sync runs: iCloud Drive turned
        // on after launch is only noticed by something still looking.
        guard settings.syncsWithICloud else {
            poll?.invalidate()
            poll = nil
            return
        }
        guard poll == nil else { return }
        let poll = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.followSwitch()
                self?.watchIfNeeded()
                _ = self?.readRemote()
            }
        }
        poll.tolerance = 5
        RunLoop.main.add(poll, forMode: .common)
        self.poll = poll
    }

    private func start() {
        guard !isRunning, let folder = Self.folderURL else { return }
        isRunning = true
        startedWith = settings.portable
        agreed = Self.loadAgreed()
        launchHoldUntil = .now + Self.absentGrace
        // Turning sync on adopts what another Mac already put there; only an empty iCloud gets this
        // Mac's settings, and only once it has stayed empty for a while — `readRemote` writes them
        // then. A file that is not readable yet is left alone: the watcher and the poll read it again
        // once it lands.
        switch readRemote() {
        case .absent, .pending:
            break
        case .adopted, .unchanged:
            // Rewrite what was adopted in the current schema. Without this, a file from an older
            // DockPlus is re-adopted at every launch and its converted values stomp any change made
            // since — measured: an old "magnifiedSize" file reset the Amount slider on each launch.
            scheduleWrite()
        }
        // The folder is not created here: on a Mac new to iCloud Drive the server's own DockPlus/
        // can still be listing, and a local one made first becomes "DockPlus 2". `writeNow` creates
        // it after `readRemote`'s grace; until a folder exists the poll watches for it.
        watch(folder)
    }

    private func stop(forgetAgreement: Bool) {
        // Before the guard: iCloud going away stops the work and keeps the agreement, so a user
        // turning sync off afterwards finds nothing running, and still means to forget it.
        if forgetAgreement { agreed = nil }
        guard isRunning else { return }
        isRunning = false
        pendingWrite?.cancel()
        pendingWrite = nil
        watcher?.cancel()
        watcher = nil
        startedWith = nil
        absentSince = nil
        stalledSince = nil
        mayWrite = false
        launchHoldUntil = nil
        lastError = nil
        lastModified = nil
    }

    private func watch(_ folder: URL) {
        // No folder yet, so nothing to watch; `watchIfNeeded` tries again on the poll.
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            let events = source?.data ?? []
            MainActor.assumeIsolated { self?.folderChanged(folder, events: events) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    private func folderChanged(_ folder: URL, events: DispatchSource.FileSystemEvent) {
        // The folder itself was deleted or moved: the descriptor now names a dead inode and would
        // never fire again, so watch the path afresh. A folder that is gone stays unwatched until
        // the poll or the next write brings it back.
        if events.contains(.delete) || events.contains(.rename) {
            watcher?.cancel()
            watcher = nil
            guard isRunning else { return }
            watch(folder)
        }
        _ = readRemote()
    }

    private func holdAfterWake() {
        guard isRunning else { return }
        launchHoldUntil = .now + Self.absentGrace
        lastModified = nil
        // The grace is wall-clock, so it would count the sleep as time the file stayed missing.
        absentSince = nil
        // A write queued before sleep still has its old, uptime-based timer; re-time it to honour
        // the hold.
        if pendingWrite != nil { scheduleWrite() }
        _ = readRemote()
    }

    private func watchIfNeeded() {
        guard isRunning, watcher == nil, let folder = Self.folderURL else { return }
        watch(folder)
    }

    private func scheduleWrite() {
        guard isRunning else { return }
        pendingWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.push() }
        }
        pendingWrite = work
        let delay = max(1, launchHoldUntil?.timeIntervalSinceNow ?? 0)
        pendingWriteDue = .now + delay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The first push after launch looks at the file again, so the write is built on what iCloud has
    /// by now. A file still downloading answers `.pending`, and the write waits for it.
    private func push() {
        // Fired long after it was due: the Mac slept, and this ran before the wake notification
        // could start the hold. Treated as a wake, so the write still re-reads the file first.
        if let due = pendingWriteDue, Date.now.timeIntervalSince(due) > Self.sleepSlack {
            launchHoldUntil = launchHoldUntil ?? .now
        }
        pendingWriteDue = nil
        if launchHoldUntil != nil {
            launchHoldUntil = nil
            lastModified = nil
            guard readRemote() != .pending else { return }
        }
        writeNow()
    }

    private func writeNow() {
        guard isRunning, mayWrite, let url = Self.fileURL else { return }
        let current = settings.portable
        guard current != agreed else { return }
        // Past the launch hold the file can still go stale (iCloud mid-download, a wake). Writing
        // over it is what reverts another Mac's edits, so ask for the copy and wait. `lastModified`
        // is forgotten so the next read looks even if the timestamp has not moved; adopting what
        // lands reschedules this write whenever the settings here still differ.
        if Self.isRemoteStale(url) {
            lastModified = nil
            noteStall()
            return
        }
        endStall()
        do {
            // The folder can be deleted in Finder while sync is on; without it every write fails.
            // Created only when absent: with no intermediates, creating an existing folder throws
            // rather than passing, which failed every write after the first.
            let folder = url.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                watchIfNeeded()
            }
            try current.encoded().write(to: url, options: .atomic)
            agreed = current
            lastModified = Self.modified(url)
            lastError = nil
        } catch {
            NSLog("DockPlus: could not write iCloud settings: \(error)")
            lastError = error.localizedDescription
        }
    }

    /// Whether the file in iCloud is one a write must not replace: evicted, a placeholder, or present
    /// but not the current version. Absent is not stale; a missing file is written like any other.
    private static func isRemoteStale(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            return fm.fileExists(
                atPath: url.deletingLastPathComponent().appendingPathComponent(".settings.json.icloud").path)
        }
        var info = stat()
        let isDataless = stat(url.path, &info) == 0 && info.st_flags & UInt32(SF_DATALESS) != 0
        let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus
        guard isDataless || (status != nil && status != .current) else { return false }
        try? fm.startDownloadingUbiquitousItem(at: url)
        return true
    }

    enum ReadResult { case adopted, unchanged, absent, pending }

    /// How late a queued write may run before it is taken to have slept through its delay.
    private static let sleepSlack: TimeInterval = 10

    /// How long a copy may stay not-current before it is reported.
    private static let stallGrace: TimeInterval = 120
    private static let stallMessage = "iCloud has not finished downloading the latest settings."

    /// How long the file must stay missing before a Mac that has never agreed on one writes its own.
    private static let absentGrace: TimeInterval = 60

    /// Applies the file when it changed since last read.
    @discardableResult
    private func readRemote() -> ReadResult {
        guard isRunning, let url = Self.fileURL else { return .pending }
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            // Evicted to save space, older iCloud: a ".settings.json.icloud" placeholder instead.
            // Ask for it back; the folder watcher sees it land.
            let placeholder = url.deletingLastPathComponent().appendingPathComponent(".settings.json.icloud")
            if fm.fileExists(atPath: placeholder.path) {
                try? fm.startDownloadingUbiquitousItem(at: url)
                return .pending
            }
            endStall()
            // Missing at the first look is not yet missing: on a Mac new to iCloud Drive the folder's
            // listing can arrive after DockPlus starts, and writing at once put this Mac's defaults
            // over the real file. Until this Mac has agreed on a file, the absence has to last a
            // minute of polls; once it has, a missing file is one deleted, and is written back at the
            // next change, as ever.
            // A remembered agreement from an earlier launch does not count: the listing can still be
            // late, so `mayWrite` stands in for "agreed during this run".
            if agreed == nil || !mayWrite {
                let since = absentSince ?? .now
                absentSince = since
                guard Date.now.timeIntervalSince(since) >= Self.absentGrace else { return .pending }
                // Forgotten, so the write is not skipped as "nothing changed" when the remembered
                // agreement equals the settings: the file is gone, whatever was agreed.
                agreed = nil
                mayWrite = true
                scheduleWrite()
                return .absent
            }
            mayWrite = true
            return .absent
        }
        absentSince = nil
        // Evicted on macOS 26: the file keeps its name but is "dataless" (`ls -lO`), and reading
        // it downloads it synchronously — on the main thread, for as long as the network takes.
        // Read it on a background queue instead, which brings it down; the watcher sees it land.
        var info = stat()
        if stat(url.path, &info) == 0, info.st_flags & UInt32(SF_DATALESS) != 0 {
            // One at a time: offline, each blocks until the network returns, and the 30 s poll and
            // every folder event would otherwise park another thread on it.
            guard !isFetching else { return .pending }
            isFetching = true
            DispatchQueue.global(qos: .utility).async { [weak self] in
                _ = try? Data(contentsOf: url)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.isFetching = false }
                }
            }
            return .pending
        }
        // Present is not current: iCloud can leave an older copy in place while it fetches the
        // newer. Adopting it, or writing over it, is what makes another Mac's edits read as reverted.
        let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus
        if let status, status != .current {
            try? fm.startDownloadingUbiquitousItem(at: url)
            noteStall()
            return .pending
        }
        endStall()
        let modified = Self.modified(url)
        if let modified, modified == lastModified { return .unchanged }
        guard let data = try? Data(contentsOf: url) else { return .pending }
        let remote: PortableSettings
        do {
            remote = try PortableSettings.decoded(from: data)
        } catch let error where PortableSettings.isFromNewerDockPlus(error) {
            return holdForNewerDockPlus()
        } catch {
            // Corrupt, not merely not here yet: answering .pending forever meant mayWrite never
            // came true and sync was silently dead on this Mac. The bytes are unrecoverable — not
            // JSON, or not a JSON object, which every schema decodes from — so this Mac's settings replace them
            // (last writer wins, as ever). Not remembered as read: until the write lands, each
            // poll retries the replacement.
            NSLog("DockPlus: the iCloud settings file does not parse; replacing it")
            lastError = "The settings file in iCloud was unreadable and is being replaced."
            agreed = nil
            mayWrite = true
            scheduleWrite()
            return .pending
        }
        if remote.isBeyondThisBuild { return holdForNewerDockPlus() }
        let local = settings.portable
        let incoming = (agreed ?? startedWith).map { PortableSettings.merged(local: local, remote: remote, base: $0) }
            ?? remote
        lastModified = modified
        agreed = remote
        mayWrite = true
        lastError = nil
        settings.apply(incoming)
        // This Mac's unsent edits, kept through the merge, go out on top of the file.
        if incoming != remote { scheduleWrite() }
        return .adopted
    }

    /// A copy that never becomes current holds every write back with nothing on screen, which looks
    /// like sync working. After a couple of minutes — longer than a download normally takes — say so.
    private func noteStall() {
        let since = stalledSince ?? .now
        stalledSince = since
        guard lastError == nil, Date.now.timeIntervalSince(since) >= Self.stallGrace else { return }
        lastError = Self.stallMessage
    }

    private func endStall() {
        guard stalledSince != nil else { return }
        stalledSince = nil
        if lastError == Self.stallMessage { lastError = nil }
    }

    /// A newer DockPlus wrote the file. Replaced as corrupt, it lost the newer Mac's settings to this
    /// one's, so this Mac neither adopts nor writes until it is updated. Writing is switched
    /// off, not merely skipped: with it left on, a write already queued or the next change here
    /// went out over the newer file, and that write's success cleared this message. A later
    /// read of a file this DockPlus understands, or of none, switches it back on.
    private func holdForNewerDockPlus() -> ReadResult {
        lastError = "The settings in iCloud are from a newer DockPlus. Update DockPlus to keep syncing."
        mayWrite = false
        pendingWrite?.cancel()
        pendingWrite = nil
        return .pending
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
