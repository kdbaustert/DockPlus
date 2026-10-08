import AppKit
import EventKit
import IOKit.pwr_mgt
import Observation

/// The data behind the bar's widget tiles. Each source runs only while its tile is on, and each
/// keeps its own cadence: the clock ticks, the weather ambles, now-playing waits for the players.
///
/// This file holds every source's state and wires the sources up; each source's behaviour lives in
/// its own file (WidgetsClock, WidgetsWeather, WidgetsNowPlaying, WidgetsBattery, WidgetsCalendar,
/// WidgetsKeepAwake).
/// An extension cannot add stored
/// properties, so the state is here — and its setters are module-wide rather than `private` only so
/// those files can write it. Views read it; nothing outside those files should assign it.
@MainActor
@Observable
final class WidgetsModel {
    static let shared = WidgetsModel(settings: .shared)

    // MARK: Clock
    var clockTime = ""
    var clockDate = ""

    // MARK: Weather
    var weatherTemperature: String?
    var weatherHighLow = ""
    var weatherSymbol = "cloud.fill"
    var weatherPlace = ""

    // MARK: Now playing
    var trackTitle: String?
    var trackArtist = ""
    var isPlaying = false
    var artwork: NSImage?
    /// A running player DockPlus is not allowed to ask, when no other answered. Denied looked exactly
    /// like nothing playing, which left no clue that a permission was the reason.
    var deniedPlayer: String?
    /// Whether `deniedPlayer` was never asked (a click can put the consent prompt up) rather than
    /// refused (only System Settings can undo that, and macOS will not re-prompt).
    var playerNeedsConsent = false
    /// A running player never asked, even while another one shows: `deniedPlayer` is only set when
    /// nothing shows, so without this the tile could offer no way to allow the player that is
    /// actually playing.
    var unaskedPlayer: String?
    /// Which player answered last — where the controls go.
    var player: String?
    /// Watches app switches only while a player is refused or never asked, to notice Automation being granted in
    /// System Settings; see `watchPlayerAccess`.
    @ObservationIgnored var playerAccessWatch: NSObjectProtocol?
    @ObservationIgnored var artworkURL: String?

    // MARK: Battery
    /// nil while the tile is off, and on a Mac with no battery.
    var battery: BatteryReading?

    // MARK: Calendar
    var calendarAccess: CalendarAccess = .notDetermined
    /// The next event's title; nil when there are no more today.
    var calendarTitle: String?
    var calendarTime = ""

    // MARK: Keep awake
    var isKeepingAwake = false
    /// When it turns itself off; nil while on indefinitely, and while off.
    var keepAwakeUntil: Date?
    /// `keepAwakeUntil` as the tile shows it.
    var keepAwakeEnd = ""

    /// Widgets are drawn on a bottom dock only (`DockModel.showItems`). On a side dock no tile shows,
    /// so none of them runs: keep awake held the display awake with nothing on screen to say so, and
    /// the weather went on fetching for a tile no one could see.
    var widgetsOnBar: Bool { settings.edge == .bottom }

    /// Set while Settings' gallery shows the tiles, so the clock and battery previews read true with
    /// the widget off. Only those two: they cost a minute timer and a power notice, where weather
    /// would fetch, and now playing and the calendar would ask macOS for permission.
    var isPreviewing = false

    @ObservationIgnored let settings: DockSettings
    @ObservationIgnored var clockTimer: Timer?
    /// Built when the clock is configured rather than per tick: two formatters a minute, forever,
    /// for output that changes only with the 24-hour setting, the time zone or the locale — each of
    /// which comes back through `configureClock`.
    @ObservationIgnored var clockTimeFormatter = DateFormatter()
    @ObservationIgnored var clockDateFormatter = DateFormatter()
    @ObservationIgnored var weatherTimer: Timer?
    @ObservationIgnored var playerNotices: PlayerNotices?
    @ObservationIgnored var weatherTask: Task<Void, Never>?
    /// The one pending retry after a failed fetch. Held so a new configuration can cancel it, and
    /// so failures replace it rather than stacking one sleeper each.
    @ObservationIgnored var weatherRetry: Task<Void, Never>?
    /// What the shown reading was fetched for — place, unit and coordinates, as `weatherKey`
    /// builds it. A failed fetch for anything different must not leave the old reading standing in
    /// for it: keyed on the place name alone, a unit toggle or new coordinates under the same name
    /// kept the wrong reading up.
    @ObservationIgnored var weatherReadingKey: String?
    /// Counts successful readings, so a retry knows whether one landed since its failure.
    @ObservationIgnored var weatherSuccesses = 0
    /// Set while a poll's osascript round trips are running; a notice arriving then waits for it
    /// rather than piling a second poll onto a player that is slow to answer.
    @ObservationIgnored var isPollingPlayer = false
    /// A notice that landed mid-poll, which may carry a newer state than the one being read. Polled
    /// for once that poll ends: no timer comes along later to catch it.
    @ObservationIgnored var needsPlayerRepoll = false
    @ObservationIgnored var batterySource: CFRunLoopSource?
    /// Made only once access is granted and the tile is on: a store opens a connection to the
    /// calendar daemon, which nothing needs otherwise.
    @ObservationIgnored var eventStore: EKEventStore?
    @ObservationIgnored var eventStoreObserver: NSObjectProtocol?
    /// The store asking for access, held until the answer. Apart from `eventStore` because turning
    /// the widget on also reconfigures it, which would drop a store mid-request.
    @ObservationIgnored var calendarAccessRequest: EKEventStore?
    /// The one pending wake-up, at the next moment the tile's answer can change — see
    /// `nextCalendarBoundary`. One-shot, never repeating.
    @ObservationIgnored var calendarTimer: Timer?
    /// Watches app switches only while access is missing, to notice it being granted in System
    /// Settings; see `configureCalendar`.
    @ObservationIgnored var calendarAccessWatch: NSObjectProtocol?
    /// Held while keeping awake; releasing it is what lets the Mac sleep again.
    @ObservationIgnored var keepAwakeAssertion: IOPMAssertionID?
    /// The one-shot end of a timed keep-awake.
    @ObservationIgnored var keepAwakeTimer: Timer?

    init(settings: DockSettings) {
        self.settings = settings
        // One observation per source, each reading only its own settings: typing a weather location
        // must not re-poll the players or rebuild the clock's timer.
        observeContinuously(ownedBy: self) { [unowned self] in
            _ = (settings.showsClock, settings.clock24Hour, isPreviewing, settings.edge)
        } onChange: { [weak self] in
            self?.configureClock()
        }
        observeContinuously(ownedBy: self) { [settings] in
            _ = (settings.showsWeather, settings.weatherLocation, settings.weatherFahrenheit,
                 settings.weatherLatitude, settings.weatherLongitude, settings.edge)
        } onChange: { [weak self] in
            self?.configureWeather()
        }
        observeContinuously(ownedBy: self) { [settings] in
            _ = (settings.showsNowPlaying, settings.edge)
        } onChange: { [weak self] in
            self?.configurePlayer()
        }
        observeContinuously(ownedBy: self) { [unowned self] in
            _ = (settings.showsBattery, isPreviewing, settings.edge)
        } onChange: { [weak self] in
            self?.configureBattery()
        }
        observeContinuously(ownedBy: self) { [settings] in
            _ = (settings.showsCalendar, settings.clock24Hour, settings.edge)
        } onChange: { [weak self] in
            self?.configureCalendar()
        }
        observeContinuously(ownedBy: self) { [settings] in
            _ = (settings.showsKeepAwake, settings.clock24Hour, settings.edge)
        } onChange: { [weak self] in
            self?.configureKeepAwake()
        }
        // The minute timer runs on a clock that stops during sleep, so after a wake it showed the
        // time the Mac went to sleep until it next fired — and then fired off the minute. A clock
        // or time zone change is the same problem without the sleep. A locale change joined them when
        // the formatters stopped being made every tick, which had picked up a new locale's AM/PM and
        // day names within the minute. The calendar's one-shot timer has the same clock, and its
        // "today" and times the same time zone and locale, so it re-reads on all four too, and so
        // does keep awake's end. The weather's 15-minute timer stops with it as well: after a night
        // asleep the tile showed last night's reading for up to 15 minutes — fetched again at once,
        // with the usual retry should the network not be back yet.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.configureClock()
                self?.refreshCalendar()
                self?.refreshKeepAwake()
                self?.configureWeather()
            }
        }
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange,
                     NSLocale.currentLocaleDidChangeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.configureClock()
                    self?.refreshCalendar()
                    self?.refreshKeepAwake()
                }
            }
        }
        configureClock()
        configureWeather()
        configurePlayer()
        configureBattery()
        configureCalendar()
        configureKeepAwake()
    }

    /// Puts the named widget on the bar, from a click or a drop — a drop of one already there only
    /// reorders it. The calendar asks for access here because this is always a click or a drag.
    func add(_ name: String) {
        guard let isOn = DockSettings.widgetSwitches[name], !settings[keyPath: isOn] else { return }
        settings[keyPath: isOn] = true
        if name == "calendar" { requestCalendarAccess() }
    }
}
