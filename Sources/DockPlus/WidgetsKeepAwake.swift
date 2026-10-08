import Foundation
import IOKit.pwr_mgt

extension WidgetsModel {
    // MARK: - Keep awake (IOKit power assertions)
    //
    // One assertion while on, none while off — nothing runs in between. The display's assertion
    // rather than the system's, as `caffeinate -d` and the keep-awake apps take it: a Mac kept awake
    // behind a dark screen reads as asleep, which is what the tile was clicked to stop. It keeps the
    // system awake too. macOS drops it with the process, so a quit or a crash cannot leave the Mac
    // unable to sleep, and it is never saved: a relaunch starts off.

    /// Turns the widget off with the tile — removed, or not drawn on a side dock: nothing else is
    /// left to show it is on.
    func configureKeepAwake() {
        guard settings.showsKeepAwake, widgetsOnBar else {
            stopKeepingAwake()
            return
        }
        formatKeepAwakeEnd()
    }

    /// Until `duration` from now, or indefinitely when nil. Called again while on, it replaces
    /// the running one rather than stacking a second assertion.
    func startKeepingAwake(for duration: TimeInterval? = nil) {
        if keepAwakeAssertion == nil {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), "DockPlus Keep Awake widget" as CFString, &id)
            // The tile stays off, which is the truth; the log says why.
            guard result == kIOReturnSuccess else {
                NSLog("DockPlus: could not keep the Mac awake: IOPMAssertionCreateWithName returned \(result)")
                return
            }
            keepAwakeAssertion = id
        }
        isKeepingAwake = true
        keepAwakeUntil = duration.map { Date.now.addingTimeInterval($0) }
        formatKeepAwakeEnd()
        scheduleKeepAwakeEnd()
    }

    func stopKeepingAwake() {
        keepAwakeTimer?.invalidate()
        keepAwakeTimer = nil
        if let keepAwakeAssertion { IOPMAssertionRelease(keepAwakeAssertion) }
        keepAwakeAssertion = nil
        isKeepingAwake = false
        keepAwakeUntil = nil
        keepAwakeEnd = ""
    }

    func toggleKeepAwake() {
        isKeepingAwake ? stopKeepingAwake() : startKeepingAwake()
    }

    /// After a wake or a clock change. The timer runs on a clock that stops during sleep, so a
    /// deadline that passed with the lid shut would otherwise wait out the sleep's length again.
    func refreshKeepAwake() {
        guard isKeepingAwake else { return }
        formatKeepAwakeEnd()
        scheduleKeepAwakeEnd()
    }

    private func scheduleKeepAwakeEnd() {
        keepAwakeTimer?.invalidate()
        keepAwakeTimer = nil
        guard let keepAwakeUntil else { return }
        guard keepAwakeUntil > .now else {
            stopKeepingAwake()
            return
        }
        let timer = Timer(fire: keepAwakeUntil, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopKeepingAwake() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        keepAwakeTimer = timer
    }

    /// The end time as the clock would show it; empty while on indefinitely.
    private func formatKeepAwakeEnd() {
        guard let keepAwakeUntil else {
            keepAwakeEnd = ""
            return
        }
        let formatter = DateFormatter.localized(settings.timeTemplate)
        keepAwakeEnd = formatter.string(from: keepAwakeUntil)
    }
}
