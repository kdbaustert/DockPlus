import XCTest
@testable import DockPlus

final class PortableSettingsTests: XCTestCase {
    func testRoundTrip() throws {
        let original = PortableSettings(
            edge: "left", iconSize: 40, iconPadding: 4, dockPadding: 6, magnifies: true, magnifiedSize: 51,
            smoothHover: true, hoverIntensity: 14, bouncesOnLaunch: false, autoHides: true,
            showsMenuBarIcon: true, pinnedApps: ["/Applications/Safari.app"], stacks: ["/Users/me/Downloads"],
            hiddenApps: []
        )
        XCTAssertEqual(try PortableSettings.decoded(from: original.encoded()), original)
    }

    /// A file from another DockPlus version carries only some keys; the rest must stay unset rather than
    /// fail the whole import.
    func testPartialFileDecodes() throws {
        let partial = try PortableSettings.decoded(from: Data(#"{"iconSize": 64, "futureSetting": 1}"#.utf8))
        XCTAssertEqual(partial.iconSize, 64)
        XCTAssertNil(partial.pinnedApps)
    }

    func testExportRoundTripsUpdateChoices() throws {
        let original = SettingsExport(
            settings: PortableSettings(iconSize: 40, pinnedApps: ["/Applications/Safari.app"]),
            updates: ["SUEnableAutomaticChecks": false, "SUAutomaticallyUpdate": true])
        XCTAssertEqual(try SettingsExport.decoded(from: original.encoded()), original)
    }

    /// The update choices sit beside the settings, so an older DockPlus still imports the settings,
    /// and a file from before them imports with no update choices.
    func testExportStaysReadableBothWays() throws {
        let export = SettingsExport(settings: PortableSettings(iconSize: 40), updates: ["SUAutomaticallyUpdate": true])
        XCTAssertEqual(try PortableSettings.decoded(from: export.encoded()), PortableSettings(iconSize: 40))

        let old = try SettingsExport.decoded(from: PortableSettings(iconSize: 40).encoded())
        XCTAssertEqual(old.settings, PortableSettings(iconSize: 40))
        XCTAssertNil(old.updates)
    }

    func testImportKeepsOnlyExportedUpdateKeys() throws {
        let file = try SettingsExport.decoded(
            from: Data(#"{"updates": {"SUAutomaticallyUpdate": true, "SUSkippedVersion": true}}"#.utf8))
        XCTAssertEqual(file.knownUpdates, ["SUAutomaticallyUpdate": true])
    }

    /// A file landing in the second before this Mac's write: what the other Mac changed comes in,
    /// this Mac's unsent edit stays, and where both changed a setting the file wins.
    func testMergeKeepsUnsentEditsAndTakesTheirs() {
        let base = PortableSettings(iconSize: 48, magnifies: true, barTint: "none")
        let local = PortableSettings(iconSize: 64, magnifies: false, barTint: "none")
        let remote = PortableSettings(iconSize: 48, magnifies: true, showsKeepAwake: true, barTint: "blue")
        let merged = PortableSettings.merged(local: local, remote: remote, base: base)
        XCTAssertEqual(merged.iconSize, 64)
        XCTAssertEqual(merged.magnifies, false)
        XCTAssertEqual(merged.barTint, "blue")
        XCTAssertEqual(merged.showsKeepAwake, true)

        let conflicting = PortableSettings(iconSize: 32, magnifies: true, barTint: "none")
        XCTAssertEqual(PortableSettings.merged(local: local, remote: conflicting, base: base).iconSize, 32)
        // Nothing changed on this Mac: the file applies whole, as before.
        XCTAssertEqual(PortableSettings.merged(local: base, remote: remote, base: base), remote)
    }

    /// Same settings, same bytes — how sync recognises a file it already agrees with.
    func testEncodingIsStable() throws {
        let settings = PortableSettings(iconSize: 48, pinnedApps: ["/b.app", "/a.app"])
        XCTAssertEqual(try settings.encoded(), try settings.encoded())
    }

    /// An old export carries only the points-based size. Converted the way both the defaults
    /// migration and `apply()` convert it: clamped to 1...2.5, snapped to the slider's 0.05 steps.
    func testLegacyMagnifiedSizeConverts() throws {
        let legacy = try PortableSettings.decoded(from: Data(#"{"magnifiedSize": 42}"#.utf8))
        XCTAssertNil(legacy.magnifyAmount)
        let size = try XCTUnwrap(legacy.magnifiedSize)
        // 42 / 36 = 1.1666…, which the slider cannot land on.
        XCTAssertEqual(legacyMagnifyAmount(magnifiedSize: size, iconSize: 36), 1.15, accuracy: 1e-9)
        XCTAssertEqual(legacyMagnifyAmount(magnifiedSize: 500, iconSize: 48), 2.5, accuracy: 1e-9)
        XCTAssertEqual(legacyMagnifyAmount(magnifiedSize: 20, iconSize: 48), 1.0, accuracy: 1e-9)
    }

    /// A hostile or hand-edited file must not carry values the Settings sliders cannot display.
    func testClampedPullsNumbersIntoSliderRanges() throws {
        let hostile = try PortableSettings.decoded(from: Data(#"""
            {"iconSize": 1e20, "iconPadding": -5, "dockPadding": 99, "magnifyAmount": 0.1,
             "magnifyReach": 50, "hoverIntensity": -1, "previewDelay": 1e20, "revealSensitivity": 0,
             "revealDelay": -3, "hideDelay": 7, "revealSpeed": 0, "hideSpeed": 1e20}
            """#.utf8)).clamped()
        XCTAssertEqual(hostile.iconSize, 128)
        XCTAssertEqual(hostile.iconPadding, 0)
        XCTAssertEqual(hostile.dockPadding, 24)
        XCTAssertEqual(hostile.magnifyAmount, 1)
        XCTAssertEqual(hostile.magnifyReach, 4)
        XCTAssertEqual(hostile.hoverIntensity, 0)
        XCTAssertEqual(hostile.previewDelay, 2)
        XCTAssertEqual(hostile.revealSensitivity, 1)
        XCTAssertEqual(hostile.revealDelay, 0)
        XCTAssertEqual(hostile.hideDelay, 2)
        XCTAssertEqual(hostile.revealSpeed, 0.25)
        XCTAssertEqual(hostile.hideSpeed, 4)
    }

    /// In-range values and absent keys pass through untouched.
    func testClampedKeepsSaneValues() {
        let sane = PortableSettings(iconSize: 48, magnifyAmount: 1.35, revealDelay: 0.5)
        XCTAssertEqual(sane.clamped(), sane)
    }

    /// Settings that deliberately stay on each Mac.
    private static let perMacKeys: Set<String> = [
        // Hiding the macOS Dock restarts it — not something one Mac should do to another.
        "hidesSystemDock",
        // Writes the macOS Dock's `no-bouncing` and restarts it, the same as the switch above.
        "systemDockBouncesForAttention",
        // The sync switch itself.
        "syncsWithICloud",
        // Display-shaped: which screen, and that screen's UUID, mean nothing on another Mac.
        "displayMode", "specificDisplay",
        // Only has an effect with a dock on every display, which is `displayMode`.
        "previewsShowOnlyThisDisplay",
        // This Mac's history of quit apps, by paths that differ between Macs; rewritten at every quit.
        "recentApps",
    ]

    /// Every setting with a registered default either travels or is on the per-Mac list, so a new
    /// setting added to Settings and forgotten in PortableSettings fails here instead of quietly
    /// never syncing. Through the file format rather than by property names: a key counts as synced
    /// only if a file carrying it under the defaults' exact name and type decodes it and writes it
    /// back — a Codable name or type that drifted from the defaults key would not.
    @MainActor
    func testEveryDefaultIsSyncedOrPerMac() throws {
        let defaults = DockSettings.registeredDefaults
        let file = try JSONSerialization.data(withJSONObject: defaults)
        let roundTripped = try PortableSettings.decoded(from: file).encoded()
        let synced = try XCTUnwrap(JSONSerialization.jsonObject(with: roundTripped) as? [String: Any])
        XCTAssertEqual(Set(defaults.keys).subtracting(synced.keys), Self.perMacKeys)
    }
}
