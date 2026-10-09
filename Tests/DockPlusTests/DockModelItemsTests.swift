import XCTest
@testable import DockPlus

/// The bar's item list, the launch bounce's timing and the minimized-window merge — the parts of
/// DockModel that are plain functions of their inputs.
final class DockModelItemsTests: XCTestCase {
    private let safari = "/Applications/Safari.app"
    private let mail = "/System/Applications/Mail.app"
    private let notes = "/System/Applications/Notes.app"
    private let spacer = spacerPrefix + "A"

    private func id(_ path: String) -> String { DockModel.key(URL(fileURLWithPath: path)) }

    private func running(_ path: String, pid: pid_t) -> DockModel.RunningApp {
        DockModel.RunningApp(pid: pid, bundleURL: URL(fileURLWithPath: path), name: "App \(pid)")
    }

    /// Every app path exists unless listed in `missing`; only `folders` are folders.
    private func items(
        pinned: [String] = [], hidden: [String] = [], stacks: [String] = [],
        running: [DockModel.RunningApp] = [], recent: [String] = [], minimized: [MinimizedWindow] = [],
        widgetOrder: [String] = canonicalWidgetOrder, enabledWidgets: Set<String> = [], edge: DockEdge = .bottom,
        anchors: [String: String] = [:], missing: Set<String> = [], folders: Set<String> = []
    ) -> [DockItem] {
        DockModel.items(
            pinned: pinned, hidden: hidden, stacks: stacks, running: running, recent: recent, minimized: minimized,
            widgetOrder: widgetOrder, enabledWidgets: enabledWidgets, edge: edge, anchors: anchors,
            fileExists: { !missing.contains($0) }, isFolder: { folders.contains($0) },
            displayName: { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent })
    }

    // MARK: - items

    func testEmptyDockIsFinderSeparatorTrash() {
        XCTAssertEqual(items().map(\.id), [DockModel.finderID, "separator", "trash"])
    }

    /// Finder cannot be hidden or moved: it leads the bar whatever the settings say.
    func testFinderAlwaysFirst() {
        let list = items(pinned: [safari], hidden: [DockModel.finderPath], running: [running(mail, pid: 2)])
        XCTAssertEqual(list.first?.id, DockModel.finderID)
        XCTAssertEqual(list.filter { $0.id == DockModel.finderID }.count, 1)
    }

    func testHiddenAppsAreLeftOutPinnedOrRunning() {
        let list = items(
            pinned: [safari, mail], hidden: [mail, notes],
            running: [running(mail, pid: 2), running(notes, pid: 3)])
        XCTAssertEqual(list.map(\.id), [DockModel.finderID, id(safari), "separator", "trash"])
    }

    /// A pinned app that is running is one tile, in its pinned place, marked running.
    func testPinnedRunningAppIsListedOnce() {
        let list = items(pinned: [safari], running: [running(notes, pid: 8), running(safari, pid: 7)])
        XCTAssertEqual(list.map(\.id), [DockModel.finderID, id(safari), id(notes), "separator", "trash"])
        let tile = list[1]
        XCTAssertTrue(tile.isPinned)
        XCTAssertTrue(tile.isRunning)
        XCTAssertEqual(tile.pid, 7)
        XCTAssertFalse(list[2].isPinned)
        XCTAssertEqual(list[2].name, "App 8")
    }

    func testRunningAppWithNoBundleIsKeyedByPid() {
        let list = items(running: [DockModel.RunningApp(pid: 9, bundleURL: nil, name: "tool")])
        XCTAssertEqual(list[1].id, "pid:9")
        XCTAssertNil(list[1].url)
    }

    func testPinnedAppThatNoLongerExistsIsSkipped() {
        let list = items(pinned: [safari, mail], missing: [mail])
        XCTAssertEqual(list.map(\.id), [DockModel.finderID, id(safari), "separator", "trash"])
    }

    /// Spacers keep their place among the pinned apps and never touch the disk.
    func testSpacersStayWhereTheyArePinned() {
        let list = items(pinned: [safari, spacer, mail], missing: [spacer])
        XCTAssertEqual(list.map(\.id), [DockModel.finderID, id(safari), spacer, id(mail), "separator", "trash"])
        XCTAssertEqual(list[2].kind, .spacer)
        XCTAssertTrue(list[2].isPinned)
    }

    /// A divider is a spacer that is as wide as the separator, so it gets everything a spacer does.
    func testDividersArePinnedLikeSpacersAtTheSeparatorsWidth() {
        let divider = dividerPrefix + "B"
        let list = items(pinned: [safari, divider, spacer], missing: [divider])
        XCTAssertEqual(list.map(\.id), [DockModel.finderID, id(safari), divider, spacer, "separator", "trash"])
        XCTAssertEqual(list[2].kind, .spacer)
        let metrics = DockMetrics()
        XCTAssertEqual(list[2].spec(for: metrics), .fixed(metrics.separatorExtent))
        XCTAssertEqual(list[3].spec(for: metrics), .fixed(metrics.iconSize * 0.55))
    }

    /// Unpinned running apps leave the bar for the tile; a pinned one that is running stays put.
    func testRunningAppsWidgetGathersOnlyUnpinnedApps() {
        let list = items(
            pinned: [safari], running: [running(safari, pid: 1), running(mail, pid: 2), running(notes, pid: 3)],
            enabledWidgets: ["runningApps"])
        XCTAssertEqual(list.map(\.id), [DockModel.finderID, id(safari), "separator", "trash", "widget:runningApps"])
        XCTAssertEqual(list.last?.apps.map(\.id), [id(mail), id(notes)])
    }

    func testRunningAppsWidgetIsAbsentWithNothingToGather() {
        let list = items(pinned: [safari], running: [running(safari, pid: 1)], enabledWidgets: ["runningApps"])
        XCTAssertFalse(list.contains { $0.kind == .runningApps })
    }

    /// A side dock shows no widgets, so gathering there would make the apps vanish.
    func testRunningAppsStayOnASideDock() {
        let list = items(running: [running(mail, pid: 2)], enabledWidgets: ["runningApps"], edge: .left)
        XCTAssertEqual(list.map(\.id), [DockModel.finderID, id(mail), "separator", "trash"])
    }

    /// A moved Finder is written into the pinned list, and stands where it was put.
    func testMovedFinderStandsWhereItWasPut() {
        let list = items(pinned: [safari, DockModel.finderPath, mail])
        XCTAssertEqual(list.map(\.id), [id(safari), DockModel.finderID, id(mail), "separator", "trash"])
    }

    /// A running app with a place stands there; one without comes after the pinned apps.
    func testAnchoredRunningAppStandsAfterItsPinnedItem() {
        let list = items(
            pinned: [safari, mail], running: [running(notes, pid: 3), running("/Applications/Maps.app", pid: 4)],
            anchors: [id(notes): id(safari)])
        XCTAssertEqual(list.map(\.id), [
            DockModel.finderID, id(safari), id(notes), id(mail), id("/Applications/Maps.app"), "separator", "trash",
        ])
    }

    func testStacksAreFoldersOnlyAndEachOnce() {
        let list = items(stacks: ["/a", "/doc.txt", "/a", "/b"], folders: ["/a", "/b"])
        XCTAssertEqual(list.map(\.id), [DockModel.finderID, "separator", "folder:/a", "folder:/b", "trash"])
        XCTAssertEqual(list[2].kind, .folder)
    }

    func testWidgetsFollowTheTrashInOrderWhenEnabled() {
        let list = items(enabledWidgets: ["clock", "weather"])
        XCTAssertEqual(list.suffix(3).map(\.id), ["trash", "widget:weather", "widget:clock"])
        XCTAssertEqual(list.last?.kind, .clock)
    }

    func testNoWidgetsWhenNoneEnabled() {
        XCTAssertFalse(items().contains { $0.id.hasPrefix("widget:") })
    }

    /// A side dock's bar is one icon wide; the widgets are bottom-only.
    func testNoWidgetsOnASideEdge() {
        for edge in [DockEdge.left, .right] {
            let list = items(enabledWidgets: Set(canonicalWidgetOrder), edge: edge)
            XCTAssertEqual(list.last?.id, "trash", "\(edge)")
        }
    }

    func testBatteryAndCalendarWidgetsHaveTheirKinds() {
        let list = items(enabledWidgets: ["battery", "calendar"])
        XCTAssertEqual(list.suffix(2).map(\.id), ["widget:calendar", "widget:battery"])
        XCTAssertEqual(list.suffix(2).map(\.kind), [.calendar, .battery])
    }

    func testKeepAwakeWidgetHasItsKind() {
        let list = items(enabledWidgets: ["keepAwake"])
        XCTAssertEqual(list.last?.id, "widget:keepAwake")
        XCTAssertEqual(list.last?.kind, .keepAwake)
    }

    /// An order saved before the battery and calendar existed still shows them, after the rest.
    func testOrderSavedBeforeNewWidgetsStillShowsThem() {
        let list = items(widgetOrder: ["clock", "weather", "nowPlaying"], enabledWidgets: ["clock", "battery", "calendar"])
        XCTAssertEqual(list.suffix(3).map(\.id), ["widget:clock", "widget:calendar", "widget:battery"])
    }

    // MARK: - recent apps

    private let notesRecent = "/System/Applications/Notes.app"
    private let maps = "/System/Applications/Maps.app"
    private let books = "/System/Applications/Books.app"
    private let music = "/System/Applications/Music.app"

    /// After the running apps, behind a separator of their own, before the stacks' separator.
    func testRecentAppsFollowTheRunningAppsBehindTheirOwnSeparator() {
        let list = items(pinned: [safari], running: [running(mail, pid: 2)], recent: [maps, books])
        XCTAssertEqual(list.map(\.id), [
            DockModel.finderID, id(safari), id(mail), "separator:recent", id(maps), id(books), "separator", "trash",
        ])
        XCTAssertEqual(list[3].kind, .separator)
        let tile = list[4]
        XCTAssertEqual(tile.kind, .app)
        XCTAssertFalse(tile.isPinned)
        XCTAssertFalse(tile.isRunning)
        XCTAssertNil(tile.pid)
        XCTAssertEqual(tile.url?.path, maps)
        XCTAssertEqual(tile.name, "Maps")
    }

    /// Only apps with no tile already, that still exist, and no more than three — the ones passed
    /// over make room for the next down the list rather than leaving it short.
    func testRecentAppsSkipAppsAlreadyOnTheBarAndStopAtThree() {
        let list = items(
            pinned: [safari], hidden: [notesRecent], running: [running(mail, pid: 2)],
            recent: [DockModel.finderPath, safari, mail, notesRecent, "/gone.app", maps, books, music, "/Applications/Extra.app"],
            missing: ["/gone.app"])
        let recents = list.drop { $0.id != "separator:recent" }.dropFirst().prefix { $0.id != "separator" }
        XCTAssertEqual(recents.map(\.id), [id(maps), id(books), id(music)])
        XCTAssertEqual(DockModel.recentAppsShown, 3)
    }

    func testNoRecentSeparatorWhenNoRecentAppQualifies() {
        let list = items(pinned: [safari], recent: [safari])
        XCTAssertFalse(list.contains { $0.id == "separator:recent" })
    }

    /// Quitting puts an app first, once — compared as the bar compares apps — and the list is capped.
    func testRecordingARecentAppMovesItFirstAndCapsTheList() {
        XCTAssertEqual(DockModel.recordingRecent(maps, in: [books, maps, music]), [maps, books, music])
        XCTAssertEqual(DockModel.recordingRecent(maps + "/", in: [maps]).count, 1)
        let long = (0..<20).map { "/Applications/App\($0).app" }
        let recorded = DockModel.recordingRecent(books, in: long)
        XCTAssertEqual(recorded.count, DockModel.recentAppsKept)
        XCTAssertEqual(recorded.first, books)
        XCTAssertEqual(recorded.last, long[DockModel.recentAppsKept - 2])
    }

    func testMinimizedWindowsSitBetweenTheStacksAndTheTrash() {
        let windows = [
            MinimizedWindow(id: 41, pid: 7, title: "Report"),
            MinimizedWindow(id: 42, pid: 99, title: ""),
        ]
        let list = items(
            stacks: ["/a"], running: [running(safari, pid: 7)], minimized: windows, folders: ["/a"])
        XCTAssertEqual(list.suffix(4).map(\.id), ["folder:/a", "min:41", "min:42", "trash"])
        let tile = list[list.count - 3]
        XCTAssertEqual(tile.kind, .minimizedWindow)
        XCTAssertEqual(tile.windowID, 41)
        XCTAssertEqual(tile.pid, 7)
        XCTAssertEqual(tile.name, "Report")
        XCTAssertEqual(tile.appName, "App 7")
        // A window whose app is not in the running list still gets its tile, just unnamed.
        XCTAssertNil(list[list.count - 2].appName)
    }

    // MARK: - bounce timing

    /// A launch that finishes almost at once still gets one whole bounce.
    func testBounceRunsAtLeastOneCycle() {
        XCTAssertEqual(DockModel.bounceRemaining(after: 0), 0.6, accuracy: 1e-9)
        XCTAssertEqual(DockModel.bounceRemaining(after: 0.05), 0.55, accuracy: 1e-9)
    }

    /// Otherwise the bounce runs to the end of the cycle it is in, never stopping mid-flight.
    func testBounceStopsAtTheEndOfItsCycle() {
        XCTAssertEqual(DockModel.bounceRemaining(after: 0.7), 0.5, accuracy: 1e-9)
        XCTAssertEqual(DockModel.bounceRemaining(after: 1.3), 0.5, accuracy: 1e-9)
    }

    /// Each display's icon rests on its own cycle boundary, wherever its bounce began.
    func testBounceRestDelayIsPerIcon() {
        let now = Date()
        XCTAssertEqual(
            DockModel.bounceRestDelay(startedAt: now - 0.7, now: now, isShown: true), 0.5, accuracy: 1e-4)
        XCTAssertEqual(
            DockModel.bounceRestDelay(startedAt: now - 0.1, now: now, isShown: true), 0.5, accuracy: 1e-4)
    }

    /// A wall-clock step backwards puts `start` in the future; the step must not be bounced out.
    func testBounceRestDelayNeverExceedsOneCycle() {
        let now = Date()
        XCTAssertEqual(DockModel.bounceRestDelay(startedAt: now + 5, now: now, isShown: true), 0.6, accuracy: 1e-9)
    }

    /// An icon that is not drawn, or never began, has nothing to finish.
    func testBounceRestDelayIsZeroWhenNotShown() {
        let now = Date()
        XCTAssertEqual(DockModel.bounceRestDelay(startedAt: now - 0.1, now: now, isShown: false), 0)
        XCTAssertEqual(DockModel.bounceRestDelay(startedAt: nil, now: now, isShown: true), 0)
    }

    // MARK: - queued minimized sweeps

    /// A sweep skipped because one was running is not lost: it runs when that one finishes.
    func testQueuedSweepKeepsWhatWasAskedWhileBusy() {
        var queue = QueuedSweep()
        XCTAssertTrue(queue.take() == nil)
        queue.add([1])
        queue.add([2, 1])
        XCTAssertEqual(queue.take(), .some([1, 2]))
        XCTAssertTrue(queue.take() == nil)
    }

    /// An every-app request swallows the targeted ones.
    func testQueuedFullSweepWins() {
        var queue = QueuedSweep()
        queue.add([1])
        queue.add(nil)
        XCTAssertEqual(queue.take(), .some(nil))
        XCTAssertTrue(queue.take() == nil)
    }

    // MARK: - minimized-window merge

    func testAppsNotAskedKeepTheirPreviousWindows() {
        let previous = [
            MinimizedWindow(id: 10, pid: 1, title: "a"),
            MinimizedWindow(id: 21, pid: 2, title: "old"),
            MinimizedWindow(id: 30, pid: 3, title: "c"),
        ]
        let merged = DockModel.merged(
            order: [1, 2, 3], answers: [2: [MinimizedWindow(id: 20, pid: 2, title: "new")]], previous: previous)
        XCTAssertEqual(merged.map(\.id), [10, 20, 30])
    }

    /// An asked app that answers "none" loses its tiles; an app no longer running loses them too.
    func testAnsweredEmptyOrQuitAppsLoseTheirWindows() {
        let previous = [MinimizedWindow(id: 10, pid: 1, title: "a"), MinimizedWindow(id: 40, pid: 4, title: "d")]
        XCTAssertEqual(DockModel.merged(order: [1], answers: [1: []], previous: previous), [])
    }

    /// Running order decides the tiles' order, not the order the answers came in.
    func testMergeFollowsRunningOrder() {
        let merged = DockModel.merged(
            order: [3, 1],
            answers: [1: [MinimizedWindow(id: 10, pid: 1, title: "")], 3: [MinimizedWindow(id: 30, pid: 3, title: "")]],
            previous: [])
        XCTAssertEqual(merged.map(\.id), [30, 10])
    }
}
