import Foundation

extension WidgetsModel {
    func configureClock() {
        clockTimer?.invalidate()
        clockTimer = nil
        guard settings.showsClock && widgetsOnBar || isPreviewing else { return }
        // New instances, not a new `dateFormat` on the old ones: the per-tick formatters these
        // replace picked up a new time zone or locale for free, and this keeps that without relying
        // on whether a long-lived formatter would follow either change on its own.
        clockTimeFormatter = .localized(settings.timeTemplate)
        clockDateFormatter = .localized("EEEMMMd")
        tickClock()
    }

    private func tickClock() {
        clockTime = clockTimeFormatter.string(from: .now)
        clockDate = clockDateFormatter.string(from: .now)
        armClockTimer()
    }

    /// One shot at the next minute's turn, re-armed from the wall clock each tick — no seconds are
    /// shown. A repeating timer counts its minutes on the machine's internal clock, whose drift
    /// from the wall clock accumulates; days of uptime in the early direction would read the time
    /// just before the minute turns and show the previous minute for most of each one. The
    /// calendar's and keep awake's one-shots recover the same way.
    private func armClockTimer() {
        clockTimer?.invalidate()
        clockTimer = nil
        // A setting or a wake while paused still repaints the tile once, but starts no timer.
        guard !isPaused else { return }
        let timer = Timer(
            fire: Date.now.addingTimeInterval(60 - Date.now.timeIntervalSince1970.truncatingRemainder(dividingBy: 60)),
            interval: 0, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickClock() }
        }
        // Late rather than early, so the minute has always turned; a second late is not seen.
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }
}

extension DateFormatter {
    /// A formatter for a skeleton such as "Hmm" or "EEEMMMd", laid out the way the locale orders and
    /// punctuates those fields. A fixed pattern put ko_KR's "오전" after the time and de_DE's
    /// "Mi. Okt. 8" in an English order. The template's H or h still forces 24 or 12 hours.
    static func localized(_ template: String, locale: Locale = .current) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }
}
