import SwiftUI

struct NowPlayingTile: View {
    let width: CGFloat
    let height: CGFloat
    private let widgets = WidgetsModel.shared

    var body: some View {
        HStack(spacing: 7) {
            Group {
                if let artwork = widgets.artwork {
                    Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: height * 0.4))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.primary.opacity(0.08))
                }
            }
            .frame(width: height * 0.82, height: height * 0.82)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(widgets.trackTitle ?? (widgets.deniedPlayer == nil ? "Nothing Playing" : "Not Allowed"))
                    .font(.system(size: 10, weight: .bold))
                    .lineLimit(1)
                Text(widgets.trackTitle == nil ? deniedHint : widgets.trackArtist)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if widgets.trackTitle != nil {
                Image(systemName: widgets.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 7)
        .widgetTile(width: width, height: height)
        .contentShape(Rectangle())
        .onTapGesture {
            if widgets.trackTitle == nil, widgets.deniedPlayer != nil {
                // Never asked: the click may put the consent prompt up. Refused: macOS will not
                // re-prompt, so System Settings is the only door.
                widgets.playerNeedsConsent ? widgets.allowPlayers() : openAutomationSettings()
            } else {
                widgets.playPause()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Now Playing")
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { widgets.playPause() }
        .accessibilityAction(named: "Next Track") { widgets.nextTrack() }
        .accessibilityAction(named: "Previous Track") { widgets.previousTrack() }
        .contextMenu {
            Button("Play/Pause") { widgets.playPause() }
            Button("Next Track") { widgets.nextTrack() }
            Button("Previous Track") { widgets.previousTrack() }
            if widgets.deniedPlayer != nil {
                if widgets.playerNeedsConsent {
                    Button("Allow Control…") { widgets.allowPlayers() }
                } else {
                    Button("Open Automation Settings…") { openAutomationSettings() }
                }
            }
            Divider()
            // The same setting as Settings ▸ Widgets ▸ Now playing.
            Button("Remove from Dock") { DockSettings.shared.showsNowPlaying = false }
            Divider()
            DockMenuFooter()
        }
    }

    /// Where the permission is granted, once the tile says it is missing.
    private var deniedHint: String {
        widgets.deniedPlayer.map { "Allow control of \($0)" } ?? ""
    }

    private func openAutomationSettings() {
        NSWorkspace.shared.openPrivacyPane("Automation")
    }

    private var accessibilityValue: String {
        if widgets.trackTitle == nil, let denied = widgets.deniedPlayer {
            return "DockPlus is not allowed to control \(denied)"
        }
        guard let title = widgets.trackTitle else { return "Nothing playing" }
        let track = widgets.trackArtist.isEmpty ? title : "\(title) by \(widgets.trackArtist)"
        return "\(track), \(widgets.isPlaying ? "playing" : "paused")"
    }
}

struct WeatherTile: View {
    let width: CGFloat
    let height: CGFloat
    private let widgets = WidgetsModel.shared

    var body: some View {
        HStack(spacing: 6) {
            Text(widgets.weatherTemperature ?? "--°")
                .font(.system(size: height * 0.42, weight: .semibold))
            Image(systemName: widgets.weatherSymbol)
                .font(.system(size: height * 0.3))
                .symbolRenderingMode(.multicolor)
            VStack(alignment: .leading, spacing: 0) {
                Text(widgets.weatherPlace)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(widgets.weatherHighLow)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 7)
        .widgetTile(width: width, height: height)
        // The symbol is decoration here; the words carry it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Weather")
        // Without a role the element is AXUnknown, and its value was never read out (measured).
        .accessibilityAddTraits(.isStaticText)
        .accessibilityValue(
            [widgets.weatherTemperature, widgets.weatherPlace, widgets.weatherHighLow]
                .compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", "))
        .contextMenu {
            // The same setting as Settings ▸ Widgets ▸ Weather.
            Button("Remove from Dock") { DockSettings.shared.showsWeather = false }
            Divider()
            DockMenuFooter()
        }
    }
}

struct ClockTile: View {
    let width: CGFloat
    let height: CGFloat
    private let widgets = WidgetsModel.shared

    var body: some View {
        VStack(spacing: 0) {
            Text(widgets.clockTime)
                .font(.system(size: height * 0.34, weight: .semibold, design: .rounded))
            Text(widgets.clockDate)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
        }
        .widgetTile(width: width, height: height)
        .accessibilityElement(children: .combine)
        .contextMenu {
            // The same setting as Settings ▸ Widgets ▸ Clock.
            Button("Remove from Dock") { DockSettings.shared.showsClock = false }
            Divider()
            DockMenuFooter()
        }
    }
}

struct BatteryTile: View {
    let width: CGFloat
    let height: CGFloat
    private let widgets = WidgetsModel.shared

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: widgets.battery?.symbol ?? "battery.0percent")
                .font(.system(size: height * 0.3))
            VStack(alignment: .leading, spacing: 0) {
                Text(widgets.battery.map { "\($0.percent)%" } ?? "--%")
                    .font(.system(size: height * 0.3, weight: .semibold))
                Text(widgets.battery?.status ?? "")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .widgetTile(width: width, height: height)
        // The symbol is decoration here; the words carry it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery")
        .accessibilityAddTraits(.isStaticText)
        .accessibilityValue(widgets.battery.map { "\($0.percent)%, \($0.status.lowercased())" } ?? "")
        .contextMenu {
            // The same setting as Settings ▸ Widgets ▸ Battery.
            Button("Remove from Dock") { DockSettings.shared.showsBattery = false }
            Divider()
            DockMenuFooter()
        }
    }
}

/// Keeps the Mac and its display from sleeping while on. A click turns it on indefinitely, or
/// off again; its menu turns it on for a while instead.
struct KeepAwakeTile: View {
    let width: CGFloat
    let height: CGFloat
    private let widgets = WidgetsModel.shared

    private static let durations: [(title: String, seconds: TimeInterval)] = [
        ("30 Minutes", 30 * 60), ("1 Hour", 60 * 60), ("2 Hours", 2 * 60 * 60),
    ]

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: widgets.isKeepingAwake ? "cup.and.saucer.fill" : "cup.and.saucer")
                .font(.system(size: height * 0.32))
                .foregroundStyle(widgets.isKeepingAwake ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 1) {
                Text(widgets.isKeepingAwake ? "Awake" : "Keep Awake")
                    .font(.system(size: 10, weight: .bold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .widgetTile(width: width, height: height)
        .contentShape(Rectangle())
        .onTapGesture { widgets.toggleKeepAwake() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Keep Awake")
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { widgets.toggleKeepAwake() }
        .contextMenu {
            if widgets.isKeepingAwake {
                Button("Turn Off") { widgets.stopKeepingAwake() }
                Divider()
            }
            ForEach(Self.durations, id: \.seconds) { duration in
                Button("Keep Awake for \(duration.title)") { widgets.startKeepingAwake(for: duration.seconds) }
            }
            Button("Keep Awake Indefinitely") { widgets.startKeepingAwake() }
            Divider()
            // The same setting as Settings ▸ Widgets ▸ Keep Awake.
            Button("Remove from Dock") { DockSettings.shared.showsKeepAwake = false }
            Divider()
            DockMenuFooter()
        }
    }

    private var subtitle: String {
        guard widgets.isKeepingAwake else { return "Click to start" }
        return widgets.keepAwakeEnd.isEmpty ? "Indefinitely" : "Until \(widgets.keepAwakeEnd)"
    }

    private var accessibilityValue: String {
        guard widgets.isKeepingAwake else { return "Off" }
        return widgets.keepAwakeEnd.isEmpty ? "On indefinitely" : "On until \(widgets.keepAwakeEnd)"
    }
}

/// Running apps that are not pinned, as small icons in one tile. Each icon does what its own tile on
/// the bar did: a click switches to the app, a drag onto the bar pins it, and its menu is the app's.
/// Settings' gallery shows it with no model, as a picture.
struct RunningAppsTile: View {
    let apps: [DockItem]
    let width: CGFloat
    let height: CGFloat
    var model: DockModel?

    var body: some View {
        let size = DockItem.runningAppsIconSize(height: height)
        let gap = DockItem.runningAppsGap
        // As many as the width holds; past that, the last slot counts the rest.
        let fits = Self.slots(width: width, inset: DockItem.runningAppsInset, gap: gap, size: size)
        let shown = apps.count > fits ? Array(apps.prefix(fits - 1)) : apps
        let rest = Array(apps.dropFirst(shown.count))
        HStack(spacing: gap) {
            ForEach(shown) { app in
                icon(app, size: size)
            }
            if !rest.isEmpty {
                Menu {
                    ForEach(rest) { app in
                        Button(app.name) { model?.open(app) }
                    }
                } label: {
                    Text("+\(rest.count)")
                        .font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: size, height: size)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .accessibilityLabel("\(rest.count) more running apps")
            }
        }
        .widgetTile(width: width, height: height)
        .contextMenu {
            // The same setting as Settings ▸ Widgets ▸ Running Apps.
            Button("Remove from Dock") { DockSettings.shared.showsRunningApps = false }
            Divider()
            DockMenuFooter()
        }
    }

    private func icon(_ app: DockItem, size: CGFloat) -> some View {
        Image(nsImage: model?.icon(for: app) ?? Self.icon(for: app))
            .resizable()
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .onTapGesture { model?.open(app) }
            .onDrag { model?.dragPayload(for: app) ?? NSItemProvider() }
            .contextMenu {
                if let model { DockContextMenu(item: app, model: model) }
            }
            .help(app.name)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(app.name)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model?.open(app) }
    }

    /// How many icons of `size` fit across `width`, never fewer than one: the inverse of
    /// `DockItem.runningAppsWidth`, which sized the tile.
    nonisolated static func slots(width: CGFloat, inset: CGFloat, gap: CGFloat, size: CGFloat) -> Int {
        max(1, Int((width - 2 * inset + gap) / (size + gap)))
    }

    /// The gallery's icons, which have no model to cache them.
    private static func icon(for app: DockItem) -> NSImage {
        app.url.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? app.pid.flatMap { NSRunningApplication(processIdentifier: $0)?.icon } ?? NSImage()
    }
}

/// The next event today. Until access is granted it stands in for the permission instead: a click
/// asks for it, or once refused, opens the pane in System Settings where it is given back.
struct CalendarTile: View {
    let width: CGFloat
    let height: CGFloat
    private let widgets = WidgetsModel.shared

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "calendar")
                .font(.system(size: height * 0.36))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .widgetTile(width: width, height: height)
        .contentShape(Rectangle())
        .onTapGesture(perform: press)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Calendar")
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { press() }
        .contextMenu {
            switch widgets.calendarAccess {
            case .granted: Button("Open Calendar") { openCalendar() }
            case .notDetermined: Button("Allow Calendar Access…") { widgets.requestCalendarAccess() }
            case .denied: Button("Open Calendar Privacy Settings…") { openPrivacySettings() }
            }
            Divider()
            // The same setting as Settings ▸ Widgets ▸ Calendar.
            Button("Remove from Dock") { DockSettings.shared.showsCalendar = false }
            Divider()
            DockMenuFooter()
        }
    }

    private var title: String {
        switch widgets.calendarAccess {
        case .granted: widgets.calendarTitle ?? "No more events"
        case .notDetermined: "Calendar"
        case .denied: "Not Allowed"
        }
    }

    private var subtitle: String {
        switch widgets.calendarAccess {
        case .granted: widgets.calendarTitle == nil ? "Today" : widgets.calendarTime
        case .notDetermined: "Click to allow access"
        case .denied: "Allow in System Settings"
        }
    }

    private var accessibilityValue: String {
        switch widgets.calendarAccess {
        case .granted:
            guard let event = widgets.calendarTitle else { return "No more events today" }
            return "\(event), \(widgets.calendarTime)"
        case .notDetermined: return "Press to allow access to your calendars"
        case .denied: return "DockPlus is not allowed to read your calendars"
        }
    }

    private func press() {
        switch widgets.calendarAccess {
        case .granted: openCalendar()
        case .notDetermined: widgets.requestCalendarAccess()
        case .denied: openPrivacySettings()
        }
    }

    private func openCalendar() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
    }

    private func openPrivacySettings() {
        NSWorkspace.shared.openPrivacyPane("Calendars")
    }
}

private extension View {
    /// The widget tiles' shared chrome: their size and the faint rounded backing.
    func widgetTile(width: CGFloat, height: CGFloat) -> some View {
        frame(width: width, height: height)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.06)))
    }
}
