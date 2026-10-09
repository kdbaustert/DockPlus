import AppKit
import EventKit

/// Where the calendar widget stands with the user's permission.
enum CalendarAccess: Sendable {
    case notDetermined
    /// Refused, restricted, or write-only — none of which can read an event.
    case denied
    case granted
}

/// One event, as the tile needs it: plain values, so choosing what to show is testable without
/// EventKit.
struct CalendarEntry: Equatable, Sendable {
    let title: String
    let start: Date
    let end: Date
}

extension WidgetsModel {
    // MARK: - Calendar (EventKit)
    //
    // Nothing polls. What the tile says changes only when the calendar does (EKEventStoreChanged),
    // when an event starts or ends, or when the day turns — so one one-shot timer waits for the
    // next of those moments and is replaced at every refresh. A day with four meetings is about ten
    // wake-ups, all of them at the moment something changes.

    func configureCalendar() {
        calendarTimer?.invalidate()
        calendarTimer = nil
        if let eventStoreObserver { NotificationCenter.default.removeObserver(eventStoreObserver) }
        eventStoreObserver = nil
        eventStore = nil
        if let calendarAccessWatch { NSWorkspace.shared.notificationCenter.removeObserver(calendarAccessWatch) }
        calendarAccessWatch = nil
        calendarTitle = nil
        calendarTime = ""
        guard settings.showsCalendar, widgetsOnBar else { return }
        calendarAccess = Self.currentCalendarAccess()
        guard calendarAccess == .granted else { return watchCalendarAccess() }
        let store = EKEventStore()
        eventStore = store
        eventStoreObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshCalendarSoon() }
        }
        refreshCalendar()
    }

    /// Asks macOS for full calendar access. Only ever from a click — turning the widget on in
    /// Settings, or the tile while it offers access — never at launch, and never because sync
    /// switched the widget on from another Mac.
    func requestCalendarAccess() {
        guard Self.currentCalendarAccess() == .notDetermined, calendarAccessRequest == nil else {
            return configureCalendar()
        }
        let store = EKEventStore()
        calendarAccessRequest = store
        store.requestFullAccessToEvents { [weak self] _, _ in
            Task { @MainActor in
                self?.calendarAccessRequest = nil
                self?.configureCalendar()
            }
        }
    }

    /// Access granted or taken away in System Settings announces nothing to the app it concerns.
    /// Leaving System Settings is what comes next, so each app switch re-checks — only while
    /// access is missing, and each check is one question to TCC, at a moment the user caused.
    private func watchCalendarAccess() {
        calendarAccessWatch = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Self.currentCalendarAccess() != self.calendarAccess else { return }
                self.configureCalendar()
            }
        }
    }

    nonisolated static func currentCalendarAccess() -> CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    /// One refresh half a second after the last change notice. A sync or a bulk edit sends a burst
    /// of EKEventStoreChanged, and each refresh is a fetch on the main thread. It takes the
    /// boundary timer's slot: the refresh it schedules sets that timer again.
    private func refreshCalendarSoon() {
        calendarTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshCalendar() }
        }
        RunLoop.main.add(timer, forMode: .common)
        calendarTimer = timer
    }

    /// Reads today's events and sets the timer for the next moment the answer can change.
    func refreshCalendar() {
        calendarTimer?.invalidate()
        calendarTimer = nil
        // Access taken away in System Settings while the widget runs announces nothing; fetches
        // just come back empty, and the tile said "No more events" instead of offering access. The
        // re-check is one local question to TCC per refresh.
        guard Self.currentCalendarAccess() == calendarAccess else { return configureCalendar() }
        guard let eventStore, calendarAccess == .granted else { return }
        let now = Date.now
        let dayStart = Calendar.current.startOfDay(for: now)
        guard let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) else { return }
        // On the main thread: one day's events is a small, local fetch.
        let predicate = eventStore.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: nil)
        let entries = eventStore.events(matching: predicate).compactMap(CalendarEntry.init(event:))
        // The dock's times read like its clock, so the two never disagree about 24-hour time.
        let formatter = DateFormatter.localized(settings.timeTemplate)
        let shown = Self.calendarEvent(in: entries, at: now)
        calendarTitle = shown?.title
        calendarTime = shown.map { Self.calendarTimeText(for: $0, at: now, time: formatter.string(from:)) } ?? ""
        // Paused: the tile is current, and `setPaused` refreshes it again on waking.
        guard !isPaused else { return }
        let timer = Timer(
            fire: Self.nextCalendarBoundary(in: entries, after: now, dayEnd: dayEnd), interval: 0, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshCalendar() }
        }
        // A few seconds late is still the right minute, and lets the wake-up share another's.
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        calendarTimer = timer
    }

    /// What the tile shows: what is on now — the latest to have started, so a meeting inside an
    /// all-afternoon block shows over the block — or else the next to start. Pure, for the tests.
    nonisolated static func calendarEvent(in entries: [CalendarEntry], at now: Date) -> CalendarEntry? {
        let current = entries.filter { $0.start <= now && $0.end > now }
        if let latest = current.max(by: { $0.start < $1.start }) { return latest }
        return entries.filter { $0.start > now }.min { $0.start < $1.start }
    }

    /// "10:00 AM" for an event still to come; "Now, until 10:30 AM" for one under way. One that runs
    /// past midnight names the day it ends ("Now, until Wed 5:00 PM"), or a Monday-to-Wednesday
    /// block reads as ending today. Ending at midnight itself is still today's. From a week out
    /// the weekday would name this week's, so the date takes its place ("until May 16 9:00 AM").
    /// Pure, for the tests: the formatter comes in as `time`.
    nonisolated static func calendarTimeText(
        for entry: CalendarEntry, at now: Date, time: (Date) -> String
    ) -> String {
        guard entry.start <= now else { return time(entry.start) }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)
        guard let tomorrow, entry.end > tomorrow else { return "Now, until \(time(entry.end))" }
        let nextWeek = calendar.date(byAdding: .day, value: 7, to: today)
        let day = nextWeek.map { entry.end >= $0 } == true
            ? entry.end.formatted(.dateTime.month(.abbreviated).day())
            : entry.end.formatted(.dateTime.weekday(.abbreviated))
        return "Now, until \(day) \(time(entry.end))"
    }

    /// The next moment the tile's answer can change: an event starting or ending, or the day
    /// ending. Pure, for the tests.
    nonisolated static func nextCalendarBoundary(in entries: [CalendarEntry], after now: Date, dayEnd: Date) -> Date {
        entries.flatMap { [$0.start, $0.end] }.filter { $0 > now }.reduce(dayEnd, min)
    }
}

extension CalendarEntry {
    /// nil for what the tile passes over: all-day events, which are not "next" at any hour,
    /// invitations the user declined, and meetings the organiser cancelled — Exchange and Google
    /// keep those on the calendar, and the tile showed a meeting that won't happen.
    init?(event: EKEvent) {
        guard !event.isAllDay, event.status != .canceled,
              event.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined
        else { return nil }
        let title = event.title ?? ""
        self.init(title: title.isEmpty ? "Untitled" : title, start: event.startDate, end: event.endDate)
    }
}
