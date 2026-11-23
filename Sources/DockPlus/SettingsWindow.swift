import AppKit
import SwiftUI

// The settings window: a System Settings-shaped sidebar of tabs with gradient icon badges and a
// search field that jumps to any individual setting, and content built from the titled cards in
// `SettingsChrome.swift`.

// MARK: - Tabs

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general, appearance, widgets, interactions, applications, stacks, about

    var id: String { rawValue }

    /// The dock's own tabs under a heading, the two bookends on their own.
    static let groups: [(header: String?, tabs: [SettingsTab])] = [
        (nil, [.general]),
        ("Dock", [.appearance, .widgets, .interactions, .applications, .stacks]),
        (nil, [.about]),
    ]

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .widgets: "Widgets"
        case .interactions: "Interactions"
        case .applications: "Applications"
        case .stacks: "Stacks"
        case .about: "About"
        }
    }

    /// Badge values kept in step with the sibling apps' settings, tab for tab.
    var gradient: (Color, Color) {
        switch self {
        case .general: (Color(hex: "#8E8E93")!, Color(hex: "#6C6C70")!)
        case .appearance: (Color(hex: "#FF8A5B")!, Color(hex: "#E0532B")!)
        case .widgets: (Color(hex: "#FFC53D")!, Color(hex: "#E09A00")!)
        case .interactions: (Color(hex: "#A96BFF")!, Color(hex: "#6B2FD6")!)
        case .applications: (Color(hex: "#5BC8A8")!, Color(hex: "#17916F")!)
        case .stacks: (Color(hex: "#3F8CFF")!, Color(hex: "#1B5FD9")!)
        case .about: (Color(hex: "#B8B8BE")!, Color(hex: "#95959B")!)
        }
    }

    /// One icon family: solid, geometric, enclosed where a shape allows it.
    var symbol: String {
        switch self {
        case .general: "gearshape.2.fill"
        case .appearance: "swatchpalette.fill"
        case .widgets: "widget.small"
        case .interactions: "cursorarrow.motionlines"
        case .applications: "square.grid.3x3.fill"
        case .stacks: "folder.fill"
        case .about: "info.circle.fill"
        }
    }
}

/// Section anchors, so the search index and the sections themselves agree on one spelling.
enum SettingsAnchor {
    static let startup = "general.startup"
    static let macOSDock = "general.macOSDock"
    static let autoHide = "interactions.autoHide"
    static let display = "general.display"
    static let permissions = "general.permissions"
    static let updates = "about.updates"
    static let widgets = "widgets.widgets"
    static let widgetOptions = "widgets.options"
    static let spacers = "widgets.spacers"
    static let theme = "appearance.theme"
    static let windows = "interactions.windows"
    static let iCloud = "general.iCloud"
    static let backup = "general.backup"
    static let position = "appearance.position"
    static let size = "appearance.size"
    static let magnification = "interactions.magnification"
    static let launching = "interactions.launching"
    static let clicking = "interactions.clicking"
    static let previews = "interactions.previews"
    static let pinned = "applications.pinned"
    static let hidden = "applications.hidden"
    static let recent = "applications.recent"
    static let stacks = "stacks.folders"
    static let build = "about.build"
}

/// One searchable setting. Hand-written rather than derived from the views: a row is findable by the
/// words someone would actually type for it, which the label alone rarely covers.
private struct SettingsIndexItem: Identifiable {
    let id: String
    let tab: SettingsTab
    let anchor: String
    let section: String
    let title: String
    let keywords: [String]

    func matches(_ query: String) -> Bool {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return false }
        let hay = ([title, section, tab.title] + keywords).joined(separator: " ").lowercased()
        return words.allSatisfy(hay.contains)
    }
}

private enum SettingsIndex {
    static let items: [SettingsIndexItem] = [
        item("menuBarIcon", .general, SettingsAnchor.startup, "Startup", "Show menu-bar icon",
             ["menu bar", "status item", "hide icon", "tray"]),
        item("startAtLogin", .general, SettingsAnchor.startup, "Startup", "Start at login",
             ["login", "launch", "boot", "autostart", "startup"]),
        item("hideSystemDock", .general, SettingsAnchor.macOSDock, "macOS Dock", "Hide the macOS Dock",
             ["system dock", "apple dock", "restore", "replace"]),
        item("systemDockBounce", .general, SettingsAnchor.macOSDock, "macOS Dock", "Let apps bounce for attention",
             ["bounce", "attention", "notify", "alert", "jump", "system dock"]),
        item("permissions", .general, SettingsAnchor.permissions, "Permissions", "Screen Recording and Accessibility",
             ["permission", "screen recording", "accessibility", "granted", "privacy"]),
        item("nowPlayingWidget", .widgets, SettingsAnchor.widgets, "Widgets", "Now playing",
             ["music", "spotify", "track", "widget", "now playing"]),
        item("weatherWidget", .widgets, SettingsAnchor.widgets, "Widgets", "Weather",
             ["weather", "temperature", "forecast", "widget"]),
        item("weatherLocation", .widgets, SettingsAnchor.widgetOptions, "Options", "Weather location",
             ["city", "state", "town", "place", "location", "search"]),
        item("clockWidget", .widgets, SettingsAnchor.widgets, "Widgets", "Clock",
             ["clock", "time", "date", "widget", "24"]),
        item("calendarWidget", .widgets, SettingsAnchor.widgets, "Widgets", "Calendar",
             ["calendar", "event", "meeting", "next", "agenda", "widget"]),
        item("batteryWidget", .widgets, SettingsAnchor.widgets, "Widgets", "Battery",
             ["battery", "charge", "charging", "power", "percent", "widget"]),
        item("runningAppsWidget", .widgets, SettingsAnchor.widgets, "Widgets", "Running apps",
             ["running", "apps", "open", "unpinned", "collect", "group", "widget"]),
        item("keepAwakeWidget", .widgets, SettingsAnchor.widgets, "Widgets", "Keep awake",
             ["awake", "sleep", "caffeinate", "caffeine", "amphetamine", "display", "screen", "widget"]),
        item("spacers", .widgets, SettingsAnchor.spacers, "Layout", "Add or remove spacers and dividers",
             ["spacer", "space", "gap", "spacing", "divider", "separator", "line", "remove", "add"]),
        item("theme", .appearance, SettingsAnchor.theme, "Theme", "Bar tint",
             ["theme", "tint", "color", "colour", "corner", "shadow", "dots"]),
        item("minimized", .interactions, SettingsAnchor.windows, "Windows", "Show minimized windows in the dock",
             ["minimized", "minimize", "windows", "tiles"]),
        item("livePreviews", .interactions, SettingsAnchor.previews, "Window previews", "Live previews",
             ["live", "preview", "refresh", "video"]),
        item("iCloudSync", .general, SettingsAnchor.iCloud, "iCloud", "Sync settings with iCloud",
             ["icloud", "sync", "cloud", "other macs", "share"]),
        item("export", .general, SettingsAnchor.backup, "Backup", "Export settings",
             ["export", "backup", "save", "json", "share"]),
        item("import", .general, SettingsAnchor.backup, "Backup", "Import settings",
             ["import", "restore", "load", "json"]),
        item("autoHide", .interactions, SettingsAnchor.autoHide, "Auto-hide", "Automatically hide and show the dock",
             ["autohide", "auto-hide", "hide", "reveal", "edge", "sensitivity", "delay", "speed"]),
        item("display", .general, SettingsAnchor.display, "Display", "Show the dock on",
             ["display", "screen", "monitor", "follow", "all displays", "primary"]),
        item("edge", .appearance, SettingsAnchor.position, "Position", "Position on screen",
             ["left", "right", "bottom", "edge", "side", "orientation"]),
        item("iconSize", .appearance, SettingsAnchor.size, "Size", "Icon size",
             ["size", "bigger", "smaller", "scale", "tile"]),
        item("iconPadding", .appearance, SettingsAnchor.size, "Size", "Icon padding",
             ["padding", "spacing", "gap", "between icons"]),
        item("dockPadding", .appearance, SettingsAnchor.size, "Size", "Dock padding",
             ["padding", "margin", "inset", "bar"]),
        item("magnify", .interactions, SettingsAnchor.magnification, "Magnification", "Magnify icons under the pointer",
             ["magnification", "zoom", "grow", "enlarge", "hover"]),
        item("magnifyAmount", .interactions, SettingsAnchor.magnification, "Magnification", "Amount",
             ["magnification", "zoom", "size", "amount", "scale"]),
        item("magnifyReach", .interactions, SettingsAnchor.magnification, "Magnification", "Reach",
             ["magnification", "reach", "spread", "falloff", "narrow", "wide"]),
        item("magnifyApproach", .interactions, SettingsAnchor.magnification, "Magnification", "Magnify as the pointer approaches",
             ["magnification", "approach", "near", "proximity"]),
        item("smoothHover", .interactions, SettingsAnchor.magnification, "Magnification", "Smooth hover animation",
             ["animation", "spring", "glide", "smooth", "hover"]),
        item("hoverIntensity", .interactions, SettingsAnchor.magnification, "Magnification", "Hover highlight",
             ["hover", "highlight", "intensity", "glow", "brightness", "opacity"]),
        item("bounce", .interactions, SettingsAnchor.launching, "Launching", "Bounce icons while apps open",
             ["bounce", "launch", "opening", "animation", "jump"]),
        item("clickHides", .interactions, SettingsAnchor.clicking, "Clicking", "Click the frontmost app's icon to hide it",
             ["click", "hide", "frontmost", "toggle", "command", "option", "modifier"]),
        item("previews", .interactions, SettingsAnchor.previews, "Window previews", "Show window previews on hover",
             ["preview", "thumbnail", "windows", "hover", "peek"]),
        item("previewDelay", .interactions, SettingsAnchor.previews, "Window previews", "Preview delay",
             ["preview", "delay", "hover", "wait"]),
        item("previewControls", .interactions, SettingsAnchor.previews, "Window previews", "Window controls",
             ["preview", "close", "controls", "title", "buttons"]),
        item("pinned", .applications, SettingsAnchor.pinned, "Pinned apps", "Pinned apps",
             ["pin", "keep in dock", "remove", "apps", "applications"]),
        item("hiddenApps", .applications, SettingsAnchor.hidden, "Hidden apps", "Hidden apps",
             ["hide", "hidden", "exclude", "never show", "helper", "background"]),
        item("recentApps", .applications, SettingsAnchor.recent, "Recent apps", "Show recent apps in the dock",
             ["recent", "suggested", "recently used", "history", "quit"]),
        item("addApplication", .applications, SettingsAnchor.pinned, "Pinned apps", "Add an application",
             ["add", "pin", "choose", "select", "app", "applications"]),
        item("stacks", .stacks, SettingsAnchor.stacks, "Folders", "Stacks",
             ["folder", "downloads", "add folder", "stack", "sort", "order", "date added", "kind",
              "grid", "menu", "view content as", "display"]),
        item("checkForUpdates", .about, SettingsAnchor.updates, "Updates", "Check for updates",
             ["update", "updates", "upgrade", "new version", "sparkle", "check", "latest", "release", "download"]),
        item("automaticUpdateChecks", .about, SettingsAnchor.updates, "Updates", "Check automatically",
             ["update", "updates", "automatic", "background", "notify", "sparkle"]),
        item("automaticUpdateInstall", .about, SettingsAnchor.updates, "Updates", "Install automatically",
             ["update", "updates", "automatic", "install", "silent", "unattended", "sparkle"]),
        item("betaUpdates", .about, SettingsAnchor.updates, "Updates", "Receive beta updates",
             ["update", "beta", "sparkle", "version", "check"]),
        item("version", .about, SettingsAnchor.build, "DockPlus", "Version",
             ["version", "build", "about"]),
        item("sourceCode", .about, SettingsAnchor.build, "DockPlus", "Source code",
             ["github", "source", "repo", "repository", "author", "created by", "credits"]),
    ]

    private static func item(
        _ id: String, _ tab: SettingsTab, _ anchor: String, _ section: String, _ title: String,
        _ keywords: [String]
    ) -> SettingsIndexItem {
        SettingsIndexItem(id: id, tab: tab, anchor: anchor, section: section, title: title, keywords: keywords)
    }
}

// MARK: - Root

private struct SettingsRootView: View {
    let settings: DockSettings
    @State private var tab: SettingsTab = .general
    @State private var query = ""
    /// Anchor a search result asked for. Cleared once the scroll has happened, so picking the same
    /// result twice still moves.
    @State private var jump: String?
    /// Anchor currently outlined. See `settingsFlash`.
    @State private var flash: String?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 212)
                .background(VisualEffectBackground(material: .sidebar))
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Deliberately no background: the window's own backdrop shows through here.
        }
        .frame(minWidth: 700, idealWidth: 760, minHeight: 500, idealHeight: 580)
        .environment(\.settingsFlash, flash)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the traffic lights, which sit over the sidebar in a full-size-content window.
            SettingsSearchField(text: $query)
                .padding(.horizontal, 10)
                .padding(.top, 38)
                .padding(.bottom, 8)

            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                tabList
            } else {
                results
            }
            Spacer(minLength: 0)
        }
    }

    private var tabList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(SettingsTab.groups.enumerated()), id: \.offset) { _, group in
                if let header = group.header {
                    Text(header)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.top, 10)
                        .padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                }
                ForEach(group.tabs) { candidate in
                    tabRow(candidate)
                }
            }
        }
        .padding(.horizontal, 8)
        .accessibilityLabel("Settings sections")
    }

    private func tabRow(_ candidate: SettingsTab) -> some View {
        Button {
            tab = candidate
        } label: {
            HStack(spacing: 9) {
                SettingsTabIcon(symbol: candidate.symbol, start: candidate.gradient.0, end: candidate.gradient.1)
                Text(candidate.title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tab == candidate ? Color.primary.opacity(0.10) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(candidate.title)
        .accessibilityAddTraits(tab == candidate ? [.isButton, .isSelected] : .isButton)
    }

    /// Search hits, each naming the tab and section it lives in — the sidebar's job the rest of the
    /// time, which is why they take its place rather than covering the content.
    @ViewBuilder
    private var results: some View {
        let hits = SettingsIndex.items.filter { $0.matches(query) }
        if hits.isEmpty {
            Text("No matches")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 6)
        } else {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(hits) { hit in
                        Button {
                            tab = hit.tab
                            query = ""
                            jump = hit.anchor
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(hit.title).font(.system(size: 12))
                                Text("\(hit.tab.title) › \(hit.section)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }

    // MARK: Detail

    private var detail: some View {
        ScrollViewReader { proxy in
            content
                .onChange(of: jump) { _, anchor in
                    guard let anchor else { return }
                    // The tab changed in the same turn, so the section being scrolled to does not
                    // exist yet; let SwiftUI build the new pane before asking for it.
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(anchor, anchor: .top)
                        }
                        flash = anchor
                        jump = nil
                    }
                }
                .onChange(of: flash) { _, anchor in
                    guard anchor != nil else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        if flash == anchor { flash = nil }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .general: GeneralPane(settings: settings)
        case .appearance: AppearancePane(settings: settings)
        case .widgets: WidgetsPane(settings: settings)
        case .interactions: InteractionsPane(settings: settings)
        case .applications: ApplicationsPane(settings: settings)
        case .stacks: StacksPane(settings: settings)
        case .about: AboutPane()
        }
    }
}

// MARK: - Window

/// Hosts the settings window: a full-size-content window with a hidden title, so the sidebar runs
/// the full height with the traffic lights over it; an ordinary app (menu bar, app-switcher entry)
/// only while it is open.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private static let shared = SettingsWindow()
    private var window: NSWindow?

    static func show() { shared.present() }

    private func present() {
        let window = self.window ?? Self.makeWindow()
        self.window = window
        window.delegate = self
        // Installed before the policy change so the menu bar is never momentarily empty.
        if NSApp.mainMenu == nil { NSApp.mainMenu = Self.makeMainMenu() }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        // The blunt form: the polite `activate()` can be declined in the moment the policy changes.
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Back to a background app when Settings goes away, on the next turn of the run loop — at
    /// `willClose` the window is still on screen. The window goes with it: closing one that is kept
    /// fires no `onDisappear` and cancels no `.task`, so the General pane's permission poll and the
    /// Widgets pane's preview ran for the life of the process. Dropping the content view ends both;
    /// the next `present()` builds a new window, and the autosave name brings its frame back.
    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [self] in
            window?.contentView = nil
            window = nil
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
            // Not miniaturizable: the macOS Dock is hidden and the minimized-tile sweep skips
            // DockPlus's own windows, so a minimized Settings had no way back but the menu bar item.
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "DockPlus Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Glass: the window paints nothing of its own, and a `.behindWindow` visual-effect view fills
        // it instead — with an opaque window underneath, the material would render as flat grey.
        window.isOpaque = false
        window.backgroundColor = .clear
        // Drawn for an opaque titlebar; over glass it reads as a scar across the top of the window.
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.contentView = glassContent()
        window.center()
        // A new name, so the size the earlier Liquid Glass version saved is not applied to this one.
        window.setFrameAutosaveName("DockPlusSettings.760")
        return window
    }

    /// One visual-effect view filling the whole frame, SwiftUI hosted on top. An `NSView` under the
    /// hosting view rather than a SwiftUI background, so it covers the titlebar strip too.
    private static func glassContent() -> NSView {
        let backdrop = NSVisualEffectView()
        backdrop.material = .underWindowBackground
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active

        let host = NSHostingView(rootView: SettingsRootView(settings: .shared))
        host.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: backdrop.topAnchor),
            host.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])
        return backdrop
    }

    /// The menu bar an ordinary app implies — including Edit, so the search field answers ⌘C and ⌘V.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide DockPlus", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        // ⌘Q closes Settings instead of quitting: DockPlus is the dock, and a reflexive ⌘Q to dismiss
        // a settings window should not take it down. Quitting stays one deliberate click away.
        appMenu.addItem(withTitle: "Close Settings", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "q")
        appMenu.addItem(withTitle: "Quit DockPlus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        return main
    }
}
