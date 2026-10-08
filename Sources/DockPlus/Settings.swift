import Foundation
import Observation

enum DockEdge: String, CaseIterable {
    case bottom, left, right

    var title: String {
        switch self {
        case .bottom: "Bottom"
        case .left: "Left"
        case .right: "Right"
        }
    }
}

/// Where the dock lives when more than one screen is attached.
enum DisplayMode: String, CaseIterable {
    /// Moves to whichever screen the pointer is on.
    case followPointer
    /// Stays on the screen with the menu bar.
    case primary
    /// Stays on one chosen screen.
    case specific
    /// A dock on every screen at once.
    case all
}

/// The magnification multiple for the old points-based setting, shared by the one-time defaults
/// migration and by importing an old settings file so the two cannot disagree. Clamped to the Amount
/// slider's 1...2.5 and snapped to its 0.05 steps: 42pt over 36pt icons is 1.1666…, and a value the
/// slider cannot land on reads as a glitch (measured: it showed as "1.17×").
func legacyMagnifyAmount(magnifiedSize: Double, iconSize: Double) -> Double {
    let ratio = magnifiedSize / iconSize
    return (min(max(ratio, 1.0), 2.5) / 0.05).rounded() * 0.05
}

/// Every widget the bar knows, in their default order. A new widget goes on the end: an order saved
/// before it existed gets it appended (below), so putting it anywhere else would give a fresh
/// install and an upgraded one two different default orders.
let canonicalWidgetOrder = ["nowPlaying", "weather", "clock", "calendar", "battery", "runningApps", "keepAwake"]

/// A saved widget order healed: each known widget once, where it first appears, then any missing
/// ones in their default order, and nothing unknown. A stored order is only ever rewritten by
/// dragging what is on the bar, so a widget missing from it — an order saved before the widget
/// existed, or a hand-edited or synced file — would otherwise never show, even when turned on.
func normalizedWidgetOrder(_ order: [String]) -> [String] {
    var seen = Set<String>()
    let kept = order.filter { canonicalWidgetOrder.contains($0) && seen.insert($0).inserted }
    return kept + canonicalWidgetOrder.filter { !seen.contains($0) }
}

@MainActor
@Observable
final class DockSettings {
    static let shared = DockSettings()

    @ObservationIgnored private let store: UserDefaults

    var edge: DockEdge { didSet { store.set(edge.rawValue, forKey: "edge") } }
    var iconSize: Double { didSet { store.set(iconSize, forKey: "iconSize") } }
    /// Gap between neighbouring icons.
    var iconPadding: Double { didSet { store.set(iconPadding, forKey: "iconPadding") } }
    /// Space between the icons and the bar's edge.
    var dockPadding: Double { didSet { store.set(dockPadding, forKey: "dockPadding") } }
    var magnifies: Bool { didSet { store.set(magnifies, forKey: "magnifies") } }
    /// How much the hovered icon grows, as a multiple of the resting size — 1.35 means 35% larger.
    var magnifyAmount: Double { didSet { store.set(magnifyAmount, forKey: "magnifyAmount") } }
    /// How many icon-widths from the pointer the growth fades to nothing.
    var magnifyReach: Double { didSet { store.set(magnifyReach, forKey: "magnifyReach") } }
    /// Grow gradually as the pointer nears the bar, instead of only once it is over it.
    var magnifyOnApproach: Bool { didSet { store.set(magnifyOnApproach, forKey: "magnifyOnApproach") } }
    /// The magnified size in points, which the layout wants; the stored setting is the multiple.
    var magnifiedSize: Double { iconSize * magnifyAmount }
    /// Icons glide after the pointer on a spring rather than snapping to it each frame.
    var smoothHover: Bool { didSet { store.set(smoothHover, forKey: "smoothHover") } }
    /// Opacity of the highlight behind the hovered icon, in percent; 0 turns it off.
    var hoverIntensity: Double { didSet { store.set(hoverIntensity, forKey: "hoverIntensity") } }
    /// Icons bounce while their app launches, as in the macOS Dock.
    var bouncesOnLaunch: Bool { didSet { store.set(bouncesOnLaunch, forKey: "bouncesOnLaunch") } }
    /// A click on the app already in front hides it instead of bringing it forward again.
    var clickHidesFrontmostApp: Bool {
        didSet { store.set(clickHidesFrontmostApp, forKey: "clickHidesFrontmostApp") }
    }
    var autoHides: Bool { didSet { store.set(autoHides, forKey: "autoHides") } }
    /// With auto-hide on: hide only while another window reaches into the bar, and otherwise stay
    /// shown. A second switch beside `autoHides` rather than turning it into a mode, so every saved
    /// setting, settings file and "Turn Hiding On/Off" keeps its meaning with nothing to migrate.
    var autoHidesOnlyWhenOverlapped: Bool {
        didSet { store.set(autoHidesOnlyWhenOverlapped, forKey: "autoHidesOnlyWhenOverlapped") }
    }
    /// How far from the screen edge, in points, the pointer counts as pushing against it.
    var revealSensitivity: Double { didSet { store.set(revealSensitivity, forKey: "revealSensitivity") } }
    /// Seconds the pointer must hold the edge before a hidden dock slides out.
    var revealDelay: Double { didSet { store.set(revealDelay, forKey: "revealDelay") } }
    /// Seconds after the pointer leaves before the dock slides away.
    var hideDelay: Double { didSet { store.set(hideDelay, forKey: "hideDelay") } }
    /// Animation speed multipliers; 2 is twice as fast.
    var revealSpeed: Double { didSet { store.set(revealSpeed, forKey: "revealSpeed") } }
    var hideSpeed: Double { didSet { store.set(hideSpeed, forKey: "hideSpeed") } }
    /// Hovering a running app shows thumbnails of its windows.
    var showsWindowPreviews: Bool { didSet { store.set(showsWindowPreviews, forKey: "showsWindowPreviews") } }
    /// Seconds the pointer rests on an icon before its previews appear.
    var previewDelay: Double { didSet { store.set(previewDelay, forKey: "previewDelay") } }
    /// Each thumbnail carries a close button and its window's title.
    var previewShowsControls: Bool { didSet { store.set(previewShowsControls, forKey: "previewShowsControls") } }
    /// The open preview panel re-captures its thumbnails while it stays up.
    var livePreviews: Bool { didSet { store.set(livePreviews, forKey: "livePreviews") } }
    /// Minimized windows appear as their own tiles beside the Trash, as in the real Dock.
    var showsMinimizedWindows: Bool { didSet { store.set(showsMinimizedWindows, forKey: "showsMinimizedWindows") } }
    // Widgets at the bar's end.
    var showsNowPlaying: Bool { didSet { store.set(showsNowPlaying, forKey: "showsNowPlaying") } }
    var showsWeather: Bool { didSet { store.set(showsWeather, forKey: "showsWeather") } }
    var showsClock: Bool { didSet { store.set(showsClock, forKey: "showsClock") } }
    /// Synced like the rest, though a Mac with no battery never shows the tile — the setting then
    /// just waits for a Mac that has one.
    var showsBattery: Bool { didSet { store.set(showsBattery, forKey: "showsBattery") } }
    /// Synced too. Turning it on in Settings is what asks for calendar access; a Mac that receives
    /// it switched on by sync shows a tile to click for access instead of a prompt out of nowhere.
    var showsCalendar: Bool { didSet { store.set(showsCalendar, forKey: "showsCalendar") } }
    /// Running apps that are not pinned leave the bar for one tile of small icons.
    var showsRunningApps: Bool { didSet { store.set(showsRunningApps, forKey: "showsRunningApps") } }
    /// Synced as the tile, never as its state: whether this Mac is being kept awake is not a setting.
    var showsKeepAwake: Bool { didSet { store.set(showsKeepAwake, forKey: "showsKeepAwake") } }
    /// The widgets' left-to-right order; only the enabled ones show.
    var widgetOrder: [String] { didSet { store.set(widgetOrder, forKey: "widgetOrder") } }
    /// Each widget's switch, by its name in `widgetOrder`.
    static let widgetSwitches: [String: ReferenceWritableKeyPath<DockSettings, Bool>] = [
        "nowPlaying": \.showsNowPlaying, "weather": \.showsWeather, "clock": \.showsClock,
        "calendar": \.showsCalendar, "battery": \.showsBattery, "runningApps": \.showsRunningApps,
        "keepAwake": \.showsKeepAwake,
    ]
    /// Coordinates picked from a city search; 0,0 (an empty patch of the Gulf of Guinea) means
    /// "unset — geocode the typed name instead".
    var weatherLatitude: Double { didSet { store.set(weatherLatitude, forKey: "weatherLatitude") } }
    var weatherLongitude: Double { didSet { store.set(weatherLongitude, forKey: "weatherLongitude") } }
    /// A place name; geocoded once per change.
    var weatherLocation: String { didSet { store.set(weatherLocation, forKey: "weatherLocation") } }
    var weatherFahrenheit: Bool { didSet { store.set(weatherFahrenheit, forKey: "weatherFahrenheit") } }
    var clock24Hour: Bool { didSet { store.set(clock24Hour, forKey: "clock24Hour") } }
    /// One template for every time on the bar: the clock, calendar and keep-awake widgets must never
    /// disagree. A template, not a pattern: the 24-hour switch picks the hour cycle and the locale
    /// picks the rest (separator, AM/PM text and where it sits), see `DateFormatter.localized`.
    var timeTemplate: String { clock24Hour ? "Hmm" : "hmma" }
    // Theme. An empty tint means the plain glass.
    var barTint: String { didSet { store.set(barTint, forKey: "barTint") } }
    var barTintIntensity: Double { didSet { store.set(barTintIntensity, forKey: "barTintIntensity") } }
    var barCornerRadius: Double { didSet { store.set(barCornerRadius, forKey: "barCornerRadius") } }
    var iconShadows: Bool { didSet { store.set(iconShadows, forKey: "iconShadows") } }
    /// The little dot under running apps — off by default; it was removed once by request.
    var showsRunningDots: Bool { didSet { store.set(showsRunningDots, forKey: "showsRunningDots") } }
    var showsMenuBarIcon: Bool { didSet { store.set(showsMenuBarIcon, forKey: "showsMenuBarIcon") } }
    /// Keep the portable settings in iCloud Drive — see SettingsSync. Per Mac, never synced itself.
    var syncsWithICloud: Bool { didSet { store.set(syncsWithICloud, forKey: "syncsWithICloud") } }
    /// Which screen the dock lives on. Per Mac, like everything display-shaped.
    var displayMode: DisplayMode { didSet { store.set(displayMode.rawValue, forKey: "displayMode") } }
    /// The chosen screen's UUID when `displayMode` is `.specific`.
    var specificDisplay: String { didSet { store.set(specificDisplay, forKey: "specificDisplay") } }
    /// With a dock on every display, each dock's previews show only the windows mostly on its own
    /// screen. Per Mac: it means nothing without `displayMode`, which is.
    var previewsShowOnlyThisDisplay: Bool {
        didSet { store.set(previewsShowOnlyThisDisplay, forKey: "previewsShowOnlyThisDisplay") }
    }
    var hidesSystemDock: Bool {
        didSet {
            store.set(hidesSystemDock, forKey: "hidesSystemDock")
            // Only the app's own settings drive the real Dock: a test's throwaway instance would
            // otherwise run `defaults write` and `killall Dock` on the machine it runs on.
            guard self === DockSettings.shared else { return }
            hidesSystemDock ? SystemDock.settingChanged() : SystemDock.restore()
        }
    }
    /// Hidden, the macOS Dock still bounces an app that asks for attention up from the screen edge,
    /// beneath the bar. Off sets its `no-bouncing`, which stops that bounce. DockPlus cannot bounce
    /// the icon itself instead: the hidden Dock's tile rising (its AX frame) is the only sign of the
    /// request, and `no-bouncing` stops that too — measured on 27.2. Per Mac, like the switch above.
    var systemDockBouncesForAttention: Bool {
        didSet {
            store.set(systemDockBouncesForAttention, forKey: "systemDockBouncesForAttention")
            if self === DockSettings.shared, hidesSystemDock { SystemDock.settingChanged() }
        }
    }
    /// Pinned app paths in dock order. Finder is not in here: like the real Dock, it is always first.
    var pinnedApps: [String] { didSet { store.set(pinnedApps, forKey: "pinnedApps") } }
    /// Folder paths shown as stacks beside the Trash.
    var stacks: [String] { didSet { store.set(stacks, forKey: "stacks") } }
    /// Each stack's sort, by its path in `stacks`; a stack missing here sorts by Date Added. Beside
    /// `stacks` rather than inside it, so that list, every settings file and every older DockPlus
    /// reading one keep the plain paths they always had. See `stackSort(for:)`.
    var stackSorts: [String: String] { didSet { store.set(stackSorts, forKey: "stackSorts") } }
    /// Each stack's display, Menu or Grid, kept the same way; a stack missing here opens as a menu.
    /// See `stackDisplay(for:)`.
    var stackDisplays: [String: String] { didSet { store.set(stackDisplays, forKey: "stackDisplays") } }
    /// App paths never shown in the dock, even while running — helpers and background tools.
    var hiddenApps: [String] { didSet { store.set(hiddenApps, forKey: "hiddenApps") } }
    /// The macOS Dock's "Show suggested and recent apps": apps quit lately, after the running ones.
    var showsRecentApps: Bool {
        didSet {
            store.set(showsRecentApps, forKey: "showsRecentApps")
            // Cleared here as well as lazily in DockModel, which sees neither a launch with the
            // switch already off nor the switch turned back on before the model next looks.
            if oldValue, !showsRecentApps, self === DockSettings.shared { recentApps = [] }
        }
    }
    /// App paths, most recently quit first — see `DockModel.recordingRecent`. Per Mac, unlike the
    /// switch above: it is this Mac's history rather than a preference, the same app sits at a
    /// different path (or nowhere) on another Mac, and it changes at every quit, which would
    /// rewrite the iCloud file each time.
    var recentApps: [String] { didSet { store.set(recentApps, forKey: "recentApps") } }

    /// What each key reads before it is first set. A property here, not inline in `init`, so a test
    /// can hold the keys against what sync carries.
    static let registeredDefaults: [String: Any] = [
        "edge": DockEdge.bottom.rawValue,
        "iconSize": 48.0,
        "iconPadding": 4.0,
        "dockPadding": 6.0,
        "magnifies": true,
        "magnifyAmount": 1.35,
        "magnifyReach": 2.0,
        "magnifyOnApproach": false,
        "smoothHover": true,
        "hoverIntensity": 14.0,
        "bouncesOnLaunch": true,
        "clickHidesFrontmostApp": false,
        "autoHides": false,
        "autoHidesOnlyWhenOverlapped": false,
        "revealSensitivity": 3.0,
        "revealDelay": 0.0,
        "hideDelay": 0.5,
        "revealSpeed": 1.0,
        "hideSpeed": 1.0,
        "showsWindowPreviews": true,
        "previewDelay": 0.5,
        "previewShowsControls": true,
        "livePreviews": true,
        "showsMinimizedWindows": true,
        "showsNowPlaying": false,
        "showsWeather": false,
        "showsClock": false,
        "showsBattery": false,
        "showsCalendar": false,
        "showsRunningApps": false,
        "showsKeepAwake": false,
        "widgetOrder": canonicalWidgetOrder,
        "weatherLocation": "",
        "weatherLatitude": 0.0,
        "weatherLongitude": 0.0,
        "weatherFahrenheit": true,
        "clock24Hour": false,
        "barTint": "",
        "barTintIntensity": 20.0,
        "barCornerRadius": 16.0,
        "iconShadows": false,
        "showsRunningDots": false,
        "showsMenuBarIcon": true,
        "syncsWithICloud": false,
        "displayMode": DisplayMode.primary.rawValue,
        "specificDisplay": "",
        "previewsShowOnlyThisDisplay": false,
        "hidesSystemDock": true,
        "systemDockBouncesForAttention": false,
        "stackSorts": [String: String](),
        "stackDisplays": [String: String](),
        "showsRecentApps": false,
        "recentApps": [String](),
    ]

    /// What each numeric setting's Settings slider offers. `PortableSettings.clamped()` pulls a
    /// synced or imported value into the same range, so the two are one constant rather than two
    /// literals that could drift. Nonisolated because `clamped()` is.
    nonisolated static let iconSizeRange: ClosedRange<Double> = 24...128
    nonisolated static let iconPaddingRange: ClosedRange<Double> = 0...24
    nonisolated static let dockPaddingRange: ClosedRange<Double> = 0...24
    nonisolated static let magnifyAmountRange: ClosedRange<Double> = 1...2.5
    nonisolated static let magnifyReachRange: ClosedRange<Double> = 1...4
    nonisolated static let hoverIntensityRange: ClosedRange<Double> = 0...40
    nonisolated static let revealSensitivityRange: ClosedRange<Double> = 1...20
    nonisolated static let revealDelayRange: ClosedRange<Double> = 0...2
    nonisolated static let hideDelayRange: ClosedRange<Double> = 0...2
    nonisolated static let revealSpeedRange: ClosedRange<Double> = 0.25...4
    nonisolated static let hideSpeedRange: ClosedRange<Double> = 0.25...4
    nonisolated static let previewDelayRange: ClosedRange<Double> = 0...2
    nonisolated static let barTintIntensityRange: ClosedRange<Double> = 0...60
    nonisolated static let barCornerRadiusRange: ClosedRange<Double> = 8...24
    nonisolated static let weatherLatitudeRange: ClosedRange<Double> = -90...90
    nonisolated static let weatherLongitudeRange: ClosedRange<Double> = -180...180

    /// A stored number held to its slider's range. A local default outside it (`defaults write`, an
    /// older build) would otherwise go out over sync, and every Mac — this one included — would
    /// refuse the file as "from a newer DockPlus"; this Mac must not write what it would not read.
    private static func ranged(_ store: UserDefaults, _ key: String, _ range: ClosedRange<Double>) -> Double {
        min(max(store.double(forKey: key), range.lowerBound), range.upperBound)
    }

    /// `store` is a parameter so a test can build one over a throwaway suite; the app only ever
    /// uses `shared`, over the standard defaults.
    init(store: UserDefaults = .standard) {
        self.store = store
        // Migrated once from the old points-based setting, so an existing install keeps its size.
        // Before `register(defaults:)`: after it, `object(forKey:)` answers with the registered
        // default and the migration could never see a missing amount. An iconSize never moved off
        // its default was never persisted, so a missing one means the old default, 48.
        if store.object(forKey: "magnifyAmount") == nil, store.object(forKey: "magnifiedSize") != nil {
            let oldIconSize = store.object(forKey: "iconSize") == nil ? 48 : store.double(forKey: "iconSize")
            if oldIconSize > 0 {
                let amount = legacyMagnifyAmount(magnifiedSize: store.double(forKey: "magnifiedSize"), iconSize: oldIconSize)
                store.set(amount, forKey: "magnifyAmount")
            }
        }
        store.register(defaults: Self.registeredDefaults)
        edge = DockEdge(rawValue: store.string(forKey: "edge") ?? "") ?? .bottom
        iconSize = Self.ranged(store, "iconSize", Self.iconSizeRange)
        iconPadding = Self.ranged(store, "iconPadding", Self.iconPaddingRange)
        dockPadding = Self.ranged(store, "dockPadding", Self.dockPaddingRange)
        magnifies = store.bool(forKey: "magnifies")
        magnifyAmount = Self.ranged(store, "magnifyAmount", Self.magnifyAmountRange)
        magnifyReach = Self.ranged(store, "magnifyReach", Self.magnifyReachRange)
        magnifyOnApproach = store.bool(forKey: "magnifyOnApproach")
        smoothHover = store.bool(forKey: "smoothHover")
        hoverIntensity = Self.ranged(store, "hoverIntensity", Self.hoverIntensityRange)
        bouncesOnLaunch = store.bool(forKey: "bouncesOnLaunch")
        clickHidesFrontmostApp = store.bool(forKey: "clickHidesFrontmostApp")
        autoHides = store.bool(forKey: "autoHides")
        autoHidesOnlyWhenOverlapped = store.bool(forKey: "autoHidesOnlyWhenOverlapped")
        revealSensitivity = Self.ranged(store, "revealSensitivity", Self.revealSensitivityRange)
        revealDelay = Self.ranged(store, "revealDelay", Self.revealDelayRange)
        hideDelay = Self.ranged(store, "hideDelay", Self.hideDelayRange)
        revealSpeed = Self.ranged(store, "revealSpeed", Self.revealSpeedRange)
        hideSpeed = Self.ranged(store, "hideSpeed", Self.hideSpeedRange)
        showsWindowPreviews = store.bool(forKey: "showsWindowPreviews")
        previewDelay = Self.ranged(store, "previewDelay", Self.previewDelayRange)
        previewShowsControls = store.bool(forKey: "previewShowsControls")
        livePreviews = store.bool(forKey: "livePreviews")
        showsMinimizedWindows = store.bool(forKey: "showsMinimizedWindows")
        showsNowPlaying = store.bool(forKey: "showsNowPlaying")
        showsWeather = store.bool(forKey: "showsWeather")
        showsClock = store.bool(forKey: "showsClock")
        showsBattery = store.bool(forKey: "showsBattery")
        showsCalendar = store.bool(forKey: "showsCalendar")
        showsRunningApps = store.bool(forKey: "showsRunningApps")
        showsKeepAwake = store.bool(forKey: "showsKeepAwake")
        // Healed like `normalizedWidgetOrder`, but names this build does not know stay: a newer
        // build's synced order carries them, and the launch merge would write a stripped copy back.
        var seenWidgets = Set<String>()
        let storedOrder = (store.stringArray(forKey: "widgetOrder") ?? canonicalWidgetOrder)
            .filter { seenWidgets.insert($0).inserted }
        widgetOrder = storedOrder + canonicalWidgetOrder.filter { !seenWidgets.contains($0) }
        weatherLocation = store.string(forKey: "weatherLocation") ?? ""
        weatherLatitude = Self.ranged(store, "weatherLatitude", Self.weatherLatitudeRange)
        weatherLongitude = Self.ranged(store, "weatherLongitude", Self.weatherLongitudeRange)
        weatherFahrenheit = store.bool(forKey: "weatherFahrenheit")
        clock24Hour = store.bool(forKey: "clock24Hour")
        barTint = store.string(forKey: "barTint") ?? ""
        barTintIntensity = Self.ranged(store, "barTintIntensity", Self.barTintIntensityRange)
        barCornerRadius = Self.ranged(store, "barCornerRadius", Self.barCornerRadiusRange)
        iconShadows = store.bool(forKey: "iconShadows")
        showsRunningDots = store.bool(forKey: "showsRunningDots")
        showsMenuBarIcon = store.bool(forKey: "showsMenuBarIcon")
        syncsWithICloud = store.bool(forKey: "syncsWithICloud")
        displayMode = DisplayMode(rawValue: store.string(forKey: "displayMode") ?? "") ?? .primary
        specificDisplay = store.string(forKey: "specificDisplay") ?? ""
        previewsShowOnlyThisDisplay = store.bool(forKey: "previewsShowOnlyThisDisplay")
        hidesSystemDock = store.bool(forKey: "hidesSystemDock")
        systemDockBouncesForAttention = store.bool(forKey: "systemDockBouncesForAttention")
        hiddenApps = store.stringArray(forKey: "hiddenApps") ?? []
        let showsRecents = store.bool(forKey: "showsRecentApps")
        showsRecentApps = showsRecents
        let recents = showsRecents ? store.stringArray(forKey: "recentApps") ?? [] : []
        if recents.isEmpty { store.set(recents, forKey: "recentApps") }
        recentApps = recents
        stackSorts = store.dictionary(forKey: "stackSorts") as? [String: String] ?? [:]
        stackDisplays = store.dictionary(forKey: "stackDisplays") as? [String: String] ?? [:]

        // First launch starts from what the macOS Dock already holds, so switching loses nothing.
        // Written straight back so the seed is taken once, not re-read from a Dock DockPlus has changed.
        let pinned = store.stringArray(forKey: "pinnedApps")
            ?? SystemDock.tilePaths("persistent-apps").filter { $0.hasSuffix(".app") }
        // Folders only, each once: the Dock's right side also holds document tiles.
        var seenFolders = Set<String>()
        let folders = SystemDock.tilePaths("persistent-others").filter { path in
            var isDirectory: ObjCBool = false
            return !path.hasSuffix(".app")
                && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
                && seenFolders.insert(path).inserted
        }
        let stacks = store.stringArray(forKey: "stacks")
            ?? (folders.isEmpty ? [NSHomeDirectory() + "/Downloads"] : folders)
        store.set(pinned, forKey: "pinnedApps")
        store.set(stacks, forKey: "stacks")
        pinnedApps = pinned
        self.stacks = stacks
    }

    // MARK: - Spacers

    /// Spacers and dividers on the dock. They live in `pinnedApps` so they order and drag like apps do.
    var spacerCount: Int { pinnedApps.filter { $0.hasPrefix(spacerPrefix) }.count }

    /// A new spacer or divider at the end of the pinned apps; drag it from there to where it belongs.
    func addSpacer(divider: Bool = false) {
        pinnedApps.append(Self.newSpacer(divider: divider))
    }

    /// A fresh entry each time: two spacers with one id would be one item to the bar.
    static func newSpacer(divider: Bool = false) -> String {
        (divider ? dividerPrefix : spacerPrefix) + UUID().uuidString
    }

    func removeAllSpacers() {
        pinnedApps.removeAll { $0.hasPrefix(spacerPrefix) }
    }
}
