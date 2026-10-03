import AppKit

extension WidgetsModel {
    // MARK: - Now playing (Spotify and Music, over AppleScript)
    //
    // AppleScript rather than the MediaRemote framework: MediaRemote needs an Apple-only
    // entitlement on current macOS, and DockFix ships a whole helper adapter to get around that.
    // The two players this Mac actually uses both script cleanly. Automation consent is asked
    // only from a click on the tile (`allowPlayers`, the controls): a poll never prompts, so a
    // switch synced from another Mac does not put a permission dialog in front of someone who
    // clicked nothing, as the calendar's `requestCalendarAccess` also refuses to.
    //
    // Polled when a player says something changed, not on a timer. A 3 s timer launched osascript
    // up to twice per beat, forever, and every launch registered as an app — so the dock rebuilt
    // for each one's start and exit too. Measured, that was nearly all of DockPlus's idle work.

    /// What an extension cannot hold as stored properties, and `Widgets.swift` does not.
    @MainActor private enum Pending {
        /// The artwork download in flight: a newer track or a clear cancels it, so a late finish
        /// of either kind writes nothing, whatever URL it was for.
        static var artwork: Task<Void, Never>?
        /// A click arrived mid-poll; the repoll it queued is allowed to ask for consent.
        static var repollAsks = false
    }

    /// The players asked, in order, with the bundle ids that tell whether each is running.
    private static let players = [(name: "Spotify", bundleID: "com.spotify.client"),
                                  (name: "Music", bundleID: "com.apple.Music")]

    func configurePlayer() {
        guard settings.showsNowPlaying, widgetsOnBar else {
            playerNotices = nil
            trackTitle = nil
            deniedPlayer = nil
            playerNeedsConsent = false
            watchPlayerAccess()
            clearArtwork()
            return
        }
        playerNotices = PlayerNotices(bundleIDs: Set(Self.players.map(\.bundleID))) { [weak self] in
            self?.pollPlayer()
        }
        pollPlayer()
    }

    /// The tile's click while no player has answered: the one place a poll may ask macOS for
    /// Automation consent.
    func allowPlayers() { pollPlayer(askingConsent: true) }

    private static let separator = "␟"

    private func pollPlayer(askingConsent: Bool = false) {
        guard settings.showsNowPlaying, widgetsOnBar else { return }
        if isPollingPlayer {
            needsPlayerRepoll = true
            Pending.repollAsks = Pending.repollAsks || askingConsent
            return
        }
        isPollingPlayer = true
        // Only players that are running: osascript for one that is not costs a process launch to
        // learn nothing.
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let apps = Self.players.filter { running.contains($0.bundleID) }
        Task { [weak self] in
            // A playing player beats a paused one: Music left paused must not hide Spotify playing.
            // A paused one shows only when nothing plays, and the first playing one ends the search.
            var shown: (app: String, parts: [String])?
            var denied: String?
            var neverAsked = false
            for player in apps {
                let app = player.name
                // Asked before the script, not left to osascript: an unanswered consent prompt
                // outlives the script's 3 s timeout and left "Nothing Playing" up after a yes. Off
                // the main thread, because a prompt blocks until it is answered.
                switch await Self.automationStatus(of: player.bundleID, asking: askingConsent) {
                case OSStatus(errAEEventWouldRequireUserConsent):
                    if denied == nil { neverAsked = true }
                    denied = denied ?? app
                    continue
                case OSStatus(errAEEventNotPermitted):
                    denied = denied ?? app
                    continue
                default: break
                }
                // The timeout bounds each Apple event a busy player sits on; the process kill in
                // runAppleScript backs it up should osascript hang anyway.
                let script = """
                    with timeout of 3 seconds
                        if application "\(app)" is running then
                            tell application "\(app)"
                                if player state is not stopped then
                                    try
                                        return (player state as string) & "\(Self.separator)" & \
                                            name of current track & "\(Self.separator)" & \
                                            artist of current track & "\(Self.separator)" & \
                                            \(app == "Spotify" ? "artwork url of current track" : "\"\"")
                                    end try
                                end if
                            end tell
                        end if
                    end timeout
                    """
                let output: String
                switch await Self.runAppleScript(script) {
                case .output(let text) where !text.isEmpty: output = text
                case .denied: denied = denied ?? app; continue
                default: continue
                }
                let parts = output.components(separatedBy: Self.separator)
                guard parts.count >= 3 else { continue }
                if shown == nil || parts[0] == "playing" { shown = (app, parts) }
                if parts[0] == "playing" { break }
            }
            guard let self else { return }
            defer {
                isPollingPlayer = false
                if needsPlayerRepoll {
                    needsPlayerRepoll = false
                    let asks = Pending.repollAsks
                    Pending.repollAsks = false
                    pollPlayer(askingConsent: asks)
                }
            }
            // Switched off while the poll ran: configurePlayer has already cleared the tile.
            guard settings.showsNowPlaying, widgetsOnBar else { return }
            deniedPlayer = shown == nil ? denied : nil
            playerNeedsConsent = deniedPlayer != nil && neverAsked
            watchPlayerAccess()
            guard let shown else {
                trackTitle = nil
                clearArtwork()
                player = nil
                return
            }
            player = shown.app
            isPlaying = shown.parts[0] == "playing"
            trackTitle = shown.parts[1]
            trackArtist = shown.parts[2]
            // Not awaited: a download that stalls (URLSession waits 60 s on an idle connection)
            // would hold the poll lock, and every notice meanwhile would only queue a re-poll.
            // loadArtwork cancels the download it replaces, so a late finish cannot clobber a newer track.
            loadArtwork(shown.parts.count > 3 ? shown.parts[3] : "")
        }
    }

    /// Automation granted in System Settings announces nothing, and a paused player sends no notice
    /// to poll on, so the tile stayed on Not Allowed until the track changed. As the calendar's
    /// access watch: while a player is refused, each app switch asks TCC again — one question, no
    /// prompt, and no osascript launched to ask it — and polls once the answer is yes.
    private func watchPlayerAccess() {
        guard deniedPlayer != nil else {
            if let playerAccessWatch { NSWorkspace.shared.notificationCenter.removeObserver(playerAccessWatch) }
            playerAccessWatch = nil
            return
        }
        guard playerAccessWatch == nil else { return }
        playerAccessWatch = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let denied = self.deniedPlayer,
                      let bundleID = Self.players.first(where: { $0.name == denied })?.bundleID,
                      Self.mayScript(bundleID)
                else { return }
                self.pollPlayer()
            }
        }
    }

    /// Whether Automation of the app is allowed, without asking the user. Anything but a yes —
    /// refused, never asked, or the app not running — reads as no.
    private static func mayScript(_ bundleID: String) -> Bool {
        determinePermission(bundleID, asking: false) == noErr
    }

    /// TCC's answer for the app: noErr, errAEEventNotPermitted (refused) or
    /// errAEEventWouldRequireUserConsent (never asked). With `asking` it may put the prompt up and
    /// wait for it, so it runs on a background queue.
    private nonisolated static func automationStatus(of bundleID: String, asking: Bool) async -> OSStatus {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: determinePermission(bundleID, asking: asking))
            }
        }
    }

    private nonisolated static func determinePermission(_ bundleID: String, asking: Bool) -> OSStatus {
        var target = AEAddressDesc()
        let created = bundleID.withCString {
            AECreateDesc(DescType(typeApplicationBundleID), $0, strlen($0), &target)
        }
        guard created == noErr else { return OSStatus(created) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(
            &target, AEEventClass(typeWildCard), AEEventID(typeWildCard), asking)
    }

    /// With the remembered URL: otherwise the same track coming back would match it and skip the
    /// download, leaving the tile with no artwork.
    private func clearArtwork() {
        Pending.artwork?.cancel()
        Pending.artwork = nil
        artwork = nil
        artworkURL = nil
    }

    private func loadArtwork(_ url: String) {
        guard url != artworkURL else { return }
        Pending.artwork?.cancel()
        Pending.artwork = nil
        artworkURL = url
        guard let remote = URL(string: url), !url.isEmpty else {
            artwork = nil
            return
        }
        Pending.artwork = Task { [weak self] in
            let data = try? await URLSession.shared.data(from: remote).0
            // Cancelled means replaced or cleared: whatever this download found is not the tile's.
            guard let self, !Task.isCancelled else { return }
            // A failed download clears rather than keeping the previous track's cover under this
            // one — URL included, so the next poll tries the download again.
            guard let data else { return clearArtwork() }
            artwork = Self.thumbnail(of: data)
        }
    }

    /// Decoded at the tile's size rather than the source's: Spotify's covers are 640 px, about
    /// 1.6 MB decoded, for a tile around 40 pt wide. 160 px is that at 2x, with room for a larger
    /// dock icon size.
    private nonisolated static func thumbnail(of data: Data) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 160,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
    }

    func playPause() { control("playpause") }
    func nextTrack() { control("next track") }
    func previousTrack() { control("previous track") }

    private func control(_ command: String) {
        // No player while one is refused: asking again is what notices the permission granted.
        guard let player else { return pollPlayer(askingConsent: true) }
        // Only if it is still running: a bare `tell` launches a player that quit since the last poll.
        let script = """
            if application "\(player)" is running then
                tell application "\(player)" to \(command)
            end if
            """
        Task {
            _ = await Self.runAppleScript(script)
            // Not left to the player's notice alone: the tile answers even if none comes.
            try? await Task.sleep(for: .milliseconds(300))
            pollPlayer()
        }
    }

    enum AppleScriptResult: Sendable {
        case output(String)
        /// Automation permission refused (-1743).
        case denied
        case failed
    }

    /// osascript in a subprocess: NSAppleScript on the main thread can beachball on a busy player.
    private nonisolated static func runAppleScript(_ source: String) async -> AppleScriptResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", source]
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                // Killed if still running after 5 s: a player wedged past the script's own timeout
                // would otherwise hold this thread, and the poll with it, indefinitely.
                let kill = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                do {
                    try process.run()
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: kill)
                    process.waitUntilExit()
                    kill.cancel()
                } catch {
                    continuation.resume(returning: .failed)
                    return
                }
                guard process.terminationStatus == 0 else {
                    let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    continuation.resume(returning: message.contains("-1743") ? .denied : .failed)
                    return
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: .output(text ?? ""))
            }
        }
    }
}

/// The players' own change notices, plus their quitting, which neither reliably announces.
///
/// The selector API because it is the only one that takes a suspension behavior: AppKit suspends
/// distributed delivery while an app is inactive, and DockPlus is never the active app, so the
/// block API's coalescing default would hold every notice until Settings happened to be open.
@MainActor
final class PlayerNotices: NSObject {
    private let bundleIDs: Set<String>
    private let onChange: @MainActor () -> Void

    init(bundleIDs: Set<String>, onChange: @escaping @MainActor () -> Void) {
        self.bundleIDs = bundleIDs
        self.onChange = onChange
        super.init()
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.spotify.client.PlaybackStateChanged", "com.apple.Music.playerInfo"] {
            distributed.addObserver(
                self, selector: #selector(playerChanged), name: .init(name), object: nil,
                suspensionBehavior: .deliverImmediately)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appTerminated), name: NSWorkspace.didTerminateApplicationNotification,
            object: nil)
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func playerChanged(_ note: Notification) {
        onChange()
    }

    @objc private func appTerminated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if let id = app?.bundleIdentifier, bundleIDs.contains(id) { onChange() }
    }
}
