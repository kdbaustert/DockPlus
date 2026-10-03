import XCTest
@testable import DockPlus

/// `apply(_:)` is fifty hand-copied lines and `portable` fifty more; a slip in one (hideSpeed set
/// from hideDelay, say) compiles, and only shows as a setting that quietly fails to sync.
final class DockSettingsApplyTests: XCTestCase {
    /// Settings over a suite of their own, removed after the test, so nothing reaches the real
    /// defaults. Pinned apps and stacks are seeded so the first-launch seeding never reads this
    /// Mac's Dock for them, and two instances start out equal.
    @MainActor
    private func makeSettings() throws -> DockSettings {
        let name = "DockPlusTests.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        store.set(["/Applications/Safari.app"], forKey: "pinnedApps")
        store.set(["/Users/me/Downloads"], forKey: "stacks")
        return DockSettings(store: store)
    }

    @MainActor
    func testApplyingItsOwnSettingsChangesNothing() throws {
        let settings = try makeSettings()
        let before = settings.portable
        settings.apply(before)
        XCTAssertEqual(settings.portable, before)
    }

    /// One setting changed at a time, each carried to a second Mac's settings by `apply`. One at a
    /// time because most settings are Bools: changed all together, a line reading the wrong Bool
    /// would usually still find the right value there.
    @MainActor
    func testEverySettingCarriesAcross() throws {
        let source = try makeSettings()
        let target = try makeSettings()
        let fresh = source.portable
        let changes: [(String, @MainActor (DockSettings) -> Void)] = [
            ("edge", { $0.edge = .left }),
            ("iconSize", { $0.iconSize = 64 }),
            ("iconPadding", { $0.iconPadding = 9 }),
            ("dockPadding", { $0.dockPadding = 11 }),
            ("magnifies", { $0.magnifies.toggle() }),
            ("magnifyAmount", { $0.magnifyAmount = 2 }),
            ("magnifyReach", { $0.magnifyReach = 3 }),
            ("magnifyOnApproach", { $0.magnifyOnApproach.toggle() }),
            ("smoothHover", { $0.smoothHover.toggle() }),
            ("hoverIntensity", { $0.hoverIntensity = 25 }),
            ("bouncesOnLaunch", { $0.bouncesOnLaunch.toggle() }),
            ("clickHidesFrontmostApp", { $0.clickHidesFrontmostApp.toggle() }),
            ("autoHides", { $0.autoHides.toggle() }),
            ("autoHidesOnlyWhenOverlapped", { $0.autoHidesOnlyWhenOverlapped.toggle() }),
            ("revealSensitivity", { $0.revealSensitivity = 12 }),
            ("revealDelay", { $0.revealDelay = 0.7 }),
            ("hideDelay", { $0.hideDelay = 1.3 }),
            ("revealSpeed", { $0.revealSpeed = 2.5 }),
            ("hideSpeed", { $0.hideSpeed = 0.75 }),
            ("showsWindowPreviews", { $0.showsWindowPreviews.toggle() }),
            ("previewDelay", { $0.previewDelay = 1.1 }),
            ("previewShowsControls", { $0.previewShowsControls.toggle() }),
            ("livePreviews", { $0.livePreviews.toggle() }),
            ("showsMinimizedWindows", { $0.showsMinimizedWindows.toggle() }),
            ("showsNowPlaying", { $0.showsNowPlaying.toggle() }),
            ("showsWeather", { $0.showsWeather.toggle() }),
            ("showsClock", { $0.showsClock.toggle() }),
            ("showsBattery", { $0.showsBattery.toggle() }),
            ("showsCalendar", { $0.showsCalendar.toggle() }),
            ("showsRunningApps", { $0.showsRunningApps.toggle() }),
            ("showsKeepAwake", { $0.showsKeepAwake.toggle() }),
            ("widgetOrder", { $0.widgetOrder = Array(canonicalWidgetOrder.reversed()) }),
            ("weatherLocation", { $0.weatherLocation = "Lisbon" }),
            ("weatherLatitude", { $0.weatherLatitude = 38.7 }),
            ("weatherLongitude", { $0.weatherLongitude = -9.1 }),
            ("weatherFahrenheit", { $0.weatherFahrenheit.toggle() }),
            ("clock24Hour", { $0.clock24Hour.toggle() }),
            ("barTint", { $0.barTint = "#FF8800" }),
            ("barTintIntensity", { $0.barTintIntensity = 45 }),
            ("barCornerRadius", { $0.barCornerRadius = 20 }),
            ("iconShadows", { $0.iconShadows.toggle() }),
            ("showsRunningDots", { $0.showsRunningDots.toggle() }),
            ("showsMenuBarIcon", { $0.showsMenuBarIcon.toggle() }),
            ("pinnedApps", { $0.pinnedApps = ["/Applications/Mail.app", "/Applications/Notes.app"] }),
            ("stacks", { $0.stacks = ["/Users/me/Documents"] }),
            ("stackSorts", { $0.stackSorts = ["/Users/me/Documents": "name"] }),
            ("stackDisplays", { $0.stackDisplays = ["/Users/me/Documents": "grid"] }),
            ("hiddenApps", { $0.hiddenApps = ["/Applications/Helper.app"] }),
            ("showsRecentApps", { $0.showsRecentApps.toggle() }),
        ]
        for (name, change) in changes {
            change(source)
            XCTAssertNotEqual(source.portable, target.portable, "\(name): the change changed nothing")
            target.apply(source.portable)
            XCTAssertEqual(target.portable, source.portable, "\(name) did not carry across")
        }

        // Every setting that travels was changed by the sweep, so one added to PortableSettings later
        // without a change here fails rather than going untested.
        let start = try fields(fresh)
        let end = try fields(source.portable)
        XCTAssertEqual(start.keys.filter { (start[$0] as? NSObject) == (end[$0] as? NSObject) }, [])

        // With everything off its default, applying its own settings still changes nothing.
        let before = source.portable
        source.apply(before)
        XCTAssertEqual(source.portable, before)
    }

    /// A local default outside a slider's range (`defaults write`) must not reach the file: every Mac
    /// would then refuse it as "from a newer DockPlus", the writer included.
    @MainActor
    func testOutOfRangeDefaultsAreClampedBeforeTheyCanSync() throws {
        let name = "DockPlusTests.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        store.set(["/Applications/Safari.app"], forKey: "pinnedApps")
        store.set(["/Users/me/Downloads"], forKey: "stacks")
        store.set(50.0, forKey: "hoverIntensity")
        store.set(-3.0, forKey: "iconSize")
        store.set(500.0, forKey: "weatherLatitude")
        let settings = DockSettings(store: store)
        XCTAssertEqual(settings.hoverIntensity, DockSettings.hoverIntensityRange.upperBound)
        XCTAssertEqual(settings.iconSize, DockSettings.iconSizeRange.lowerBound)
        XCTAssertEqual(settings.weatherLatitude, DockSettings.weatherLatitudeRange.upperBound)
        XCTAssertFalse(settings.portable.isBeyondThisBuild)
    }

    /// A newer build's synced order can name a widget this one lacks; the launch merge would write
    /// a stripped copy back to iCloud as a local edit.
    @MainActor
    func testWidgetOrderKeepsNamesThisBuildDoesNotKnow() throws {
        let name = "DockPlusTests.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        store.set(["/Applications/Safari.app"], forKey: "pinnedApps")
        store.set(["/Users/me/Downloads"], forKey: "stacks")
        store.set(["stocks", "clock", "stocks", "weather"], forKey: "widgetOrder")
        let settings = DockSettings(store: store)
        let missing = canonicalWidgetOrder.filter { $0 != "clock" && $0 != "weather" }
        XCTAssertEqual(settings.widgetOrder, ["stocks", "clock", "weather"] + missing)
    }

    private func fields(_ settings: PortableSettings) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: settings.encoded()) as? [String: Any])
    }
}
