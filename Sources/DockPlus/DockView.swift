import SwiftUI

struct DockView: View {
    let model: DockModel
    let state: PanelState
    let settings: DockSettings

    var body: some View {
        let layout = model.layout(for: state)
        let metrics = layout.metrics
        // No highlight or name while an icon is carried: the pointer is over its gap.
        // Nor while the pointer is only approaching: magnification eases in then, but the controller
        // treats nothing as hovered until the pointer is on the bar.
        let hovered = model.drag == nil && state.isOverBar ? state.pointer.flatMap(layout.index(at:)) : nil
        let edge = settings.edge
        let horizontal = edge == .bottom
        let row = horizontal
            ? AnyLayout(HStackLayout(alignment: .bottom, spacing: metrics.spacing))
            : AnyLayout(VStackLayout(alignment: edge == .left ? .leading : .trailing, spacing: metrics.spacing))

        ZStack(alignment: edge.alignment) {
            Rectangle()
                .fill(.clear)
                .frame(
                    width: horizontal ? layout.length : metrics.thickness,
                    height: horizontal ? metrics.thickness : layout.length
                )
                .glassEffect(.regular, in: .rect(cornerRadius: settings.barCornerRadius))
                // The tint sits over the glass, so the desktop still shows through the colour.
                .overlay {
                    if let tint = Color(hex: settings.barTint) {
                        RoundedRectangle(cornerRadius: settings.barCornerRadius, style: .continuous)
                            .fill(tint.opacity(settings.barTintIntensity / 100))
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .accessibilityLabel("Dock")
                .contextMenu {
                    Button("Add Spacer") { model.addSpacer() }
                    Button("Add Divider") { model.addSpacer(divider: true) }
                    Divider()
                    DockMenuFooter()
                }
                .onDrop(of: DockModel.dropTypes, isTargeted: nil) { model.handleDrop($0, onto: nil) }
                .padding(edge.alongStart, layout.start)

            row {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                    let size = index < layout.sizes.count ? layout.sizes[index] : metrics.iconSize
                    Group {
                        switch item.kind {
                        case .separator:
                            SeparatorView(extent: size, iconSize: metrics.iconSize, horizontal: horizontal)
                        case .spacer:
                            SpacerTile(item: item, extent: size, iconSize: metrics.iconSize, horizontal: horizontal, model: model)
                        case .minimizedWindow:
                            MinimizedTile(item: item, extent: size, iconSize: metrics.iconSize, horizontal: horizontal, model: model)
                        case .nowPlaying:
                            NowPlayingTile(width: size, height: metrics.iconSize).dockDraggable(item, model)
                        case .weather:
                            WeatherTile(width: size, height: metrics.iconSize).dockDraggable(item, model)
                        case .clock:
                            ClockTile(width: size, height: metrics.iconSize).dockDraggable(item, model)
                        case .battery:
                            BatteryTile(width: size, height: metrics.iconSize).dockDraggable(item, model)
                        case .calendar:
                            CalendarTile(width: size, height: metrics.iconSize).dockDraggable(item, model)
                        case .keepAwake:
                            KeepAwakeTile(width: size, height: metrics.iconSize).dockDraggable(item, model)
                        case .runningApps:
                            // No drag of the tile itself: each icon in it drags its own app.
                            RunningAppsTile(apps: item.apps, width: size, height: metrics.iconSize, model: model)
                                .onDrop(of: DockModel.dropTypes, isTargeted: nil) { model.handleDrop($0, onto: item) }
                        case .app, .folder, .trash:
                            DockIcon(
                                item: item, size: size, isHovered: index == hovered, edge: edge,
                                isDockHidden: state.isHidden, bounceHeight: metrics.iconSize * 0.5,
                                model: model)
                        }
                    }
                    // The carried icon's slot is its gap: there, holding the space, but empty.
                    // An Esc-cancelled drag has already put the icon back, so only a live one hides it.
                    .opacity(model.drag.map { $0.id == item.id && !$0.cancelled } == true ? 0 : 1)
                }
            }
            .padding(edge.alongStart, layout.start + metrics.padding)
            .padding(edge.screenEdge, metrics.padding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edge.alignment)
        .offset(state.isHidden ? edge.hiddenOffset(metrics.thickness + 8) : .zero)
    }
}

private struct DockIcon: View {
    let item: DockItem
    let size: CGFloat
    let isHovered: Bool
    let edge: DockEdge
    let isDockHidden: Bool
    /// Half the fitted resting icon size, the same size the hidden offset is measured from: the
    /// unfitted setting bounced a crowded, shrunken bar's icons out over the screen edge.
    let bounceHeight: CGFloat
    let model: DockModel
    @State private var isTargeted = false

    /// Never while the dock is hidden: it sits just past the screen edge, and a lift would show the
    /// icon above it on every launch anywhere.
    private var isBouncing: Bool {
        model.settings.bouncesOnLaunch && !isDockHidden && model.launching.contains(item.id)
    }

    var body: some View {
        Image(nsImage: model.icon(for: item))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .overlay(alignment: .topTrailing) {
                if let badge = model.badges[item.id] { BadgeView(text: badge, iconSize: size) }
            }
            // Bounces away from the screen edge while the app launches. Before the highlight and
            // label: an offset moves what is drawn, not the frame, so those stay put and only the
            // icon itself jumps. When `repeating` goes false the track freezes wherever it is, so
            // the lift applies only while bouncing: a launch that ended on the timeout, mid-cycle,
            // left the icon hanging half an icon up until DockPlus restarted.
            .keyframeAnimator(initialValue: CGFloat(0), repeating: isBouncing) {
                [edge, isBouncing] icon, lift in
                icon.offset(edge.hiddenOffset(isBouncing ? -lift : 0))
            } keyframes: { [bounce = bounceHeight] _ in
                // A thrown ball, as the macOS Dock's launch bounce moves: decelerating to the top,
                // accelerating back down, and straight into the next with no rest between. Height
                // from the resting size, so a magnified icon does not bounce higher.
                // `DockModel.bounceCycle` must equal the two durations — the bounce stops only on
                // a whole cycle, so the icon is never left in the air.
                KeyframeTrack {
                    LinearKeyframe(bounce, duration: 0.3, timingCurve: .easeOut)
                    LinearKeyframe(0, duration: 0.3, timingCurve: .easeIn)
                }
            }
            // Where the stop is timed from; see `DockModel.bounceChanged`.
            .onChange(of: isBouncing, initial: true) { _, bouncing in
                model.bounceChanged(item.id, isBouncing: bouncing)
            }
            // Lit for a file dropped on the app, not for an icon passing over while being reordered.
            .brightness(isTargeted && model.drag == nil ? 0.15 : 0)
            .shadow(color: .black.opacity(model.settings.iconShadows ? 0.35 : 0), radius: 3, y: 1)
            .overlay(alignment: edge.dotAlignment) {
                if model.settings.showsRunningDots, item.isRunning, item.kind == .app {
                    Circle()
                        .fill(.primary.opacity(0.75))
                        .frame(width: 4, height: 4)
                        .offset(edge.hiddenOffset(model.metrics.padding / 2 + 2))
                }
            }
            // Reaches half the icon padding past the icon, so neighbouring highlights never touch.
            .background {
                if isHovered {
                    RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                        .fill(.primary.opacity(model.settings.hoverIntensity / 100))
                        .padding(-model.metrics.spacing / 2)
                        // Every pointer update is animated (see DockController.tick), so without
                        // this the old highlight and label fade out while the new ones fade in, and
                        // two names overlap. They move with the pointer, so they switch instantly.
                        .transition(.identity)
                }
            }
            .overlay(alignment: edge.labelAlignment) {
                // Fades in, as DockFix's does, but vanishes at once, so the outgoing name never
                // overlaps the incoming one.
                if isHovered { label.transition(.asymmetric(insertion: .opacity, removal: .identity)) }
            }
            .contentShape(Rectangle())
            // The keys held now, at the click, for Command- and Option-clicks.
            .onTapGesture { model.click(item, modifiers: NSEvent.modifierFlags) }
            .contextMenu { DockContextMenu(item: item, model: model) }
            // The icon alone, at its size: the default picture was the whole view, hover highlight and
            // name label included.
            .onDrag { model.dragPayload(for: item) } preview: {
                Image(nsImage: model.icon(for: item))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
            }
            .onDrop(of: DockModel.dropTypes, isTargeted: $isTargeted) { model.handleDrop($0, onto: item) }
            // One element per icon, read by its name: the hover label and the badge are drawn
            // children, and would otherwise be read out as separate items.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.name)
            .accessibilityValue(accessibilityValue)
            .accessibilityAddTraits(.isButton)
            // The tap gesture is not an action VoiceOver can press; this is.
            .accessibilityAction { model.click(item, modifiers: []) }
            // The context menu's shortcuts. Unhide needs none: the press above brings a hidden app back.
            .accessibilityActions {
                if item.kind == .app, item.isRunning {
                    Button("Hide") { model.hide(item) }
                }
                if item.url != nil {
                    Button("Show in Finder") { model.reveal(item) }
                }
            }
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if item.kind == .app, item.isRunning { parts.append("running") }
        // Neither pinned nor running, an app tile can only be one of the recent apps.
        if item.kind == .app, !item.isPinned, !item.isRunning { parts.append("recent") }
        if isBouncing { parts.append("launching") }
        if let badge = model.badges[item.id] { parts.append("badge \(badge)") }
        if item.kind == .trash, model.trashIsFull { parts.append("full") }
        return parts.joined(separator: ", ")
    }

    /// The name, beside the icon on the side away from the screen edge. The overlay puts a zero-size
    /// frame on the icon's edge and the label hangs off it outward, 10 points clear — no need to know
    /// the label's size. (Alignment guides on the label were tried first and were ignored: the label
    /// sat over the top half of the icon.)
    @ViewBuilder private var label: some View {
        let text = Text(item.name)
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .glassEffect(.regular, in: .capsule)
        switch edge {
        case .bottom: text.frame(height: 0, alignment: .bottom).offset(y: -10)
        case .left: text.frame(width: 0, alignment: .leading).offset(x: 10)
        case .right: text.frame(width: 0, alignment: .trailing).offset(x: -10)
        }
    }
}

private struct SeparatorView: View {
    let extent: CGFloat
    let iconSize: CGFloat
    let horizontal: Bool

    var body: some View {
        DividerLine(iconSize: iconSize, horizontal: horizontal)
            .frame(width: horizontal ? extent : iconSize, height: horizontal ? iconSize : extent)
            .contentShape(Rectangle())
            .contextMenu { DockMenuFooter() }
            .accessibilityHidden(true)
    }
}

/// The separator's line, which a placed divider draws too.
struct DividerLine: View {
    let iconSize: CGFloat
    let horizontal: Bool

    var body: some View {
        Rectangle()
            .fill(.primary.opacity(0.25))
            .frame(width: horizontal ? 1 : iconSize * 0.75, height: horizontal ? iconSize * 0.75 : 1)
    }
}

private struct DockItemMenu: View {
    let item: DockItem
    let model: DockModel

    var body: some View {
        switch item.kind {
        case .app:
            if item.isRunning, let pid = item.pid {
                AppWindowList(pid: pid, model: model)
                Button("Show All Windows") { model.showAllWindows(item) }
                // Read as the menu is built, and built again on every open through its item's count:
                // hiding an app changes nothing else the menu reads, so a reopened menu went on
                // offering Hide for a hidden app.
                let _ = model.menuOpens(of: item.id)
                if NSRunningApplication(processIdentifier: pid)?.isHidden == true {
                    Button("Unhide") { model.unhide(item) }
                } else {
                    Button("Hide") { model.hide(item) }
                }
                Divider()
            }
            if item.isRunning && item.id != DockModel.finderID {
                Button("Quit") { model.quit(item) }
                Button("Force Quit") { model.forceQuit(item) }
                Divider()
            }
            if item.id != DockModel.finderID {
                if item.isPinned {
                    Button("Remove from Dock") { model.unpin(item) }
                } else {
                    Button("Keep in Dock") { model.pin(item) }
                }
                if item.url != nil {
                    Button("Hide from Dock") { model.hideFromDock(item) }
                }
            }
            if let url = item.url, let bundleID = Bundle(url: url)?.bundleIdentifier {
                // Finder always opens at login; the macOS Dock does not offer it there either.
                AssignToMenu(itemID: item.id, bundleID: bundleID, app: url, pid: item.pid,
                             offersOpenAtLogin: item.id != DockModel.finderID, model: model)
            }
            if item.url != nil {
                Button("Show in Finder") { model.reveal(item) }
            }
        case .folder:
            // What a click does, so a Grid stack opens as its grid.
            Button("Open") { model.click(item, modifiers: []) }
            Button("Show in Finder") { model.reveal(item) }
            if let url = item.url {
                StackSortMenu(path: url.path, settings: model.settings)
                StackDisplayMenu(path: url.path, settings: model.settings)
            }
            Divider()
            Button("Remove from Dock") { model.unpin(item) }
        case .trash:
            Button("Open") { model.open(item) }
            Button("Empty Trash") { model.emptyTrash() }
        case .minimizedWindow:
            Button("Restore") { model.open(item) }
            if let windowID = item.windowID, let pid = item.pid {
                Button("Close Window") { WindowActions.close(windowID, pid: pid) }
            }
        case .spacer:
            Button("Remove from Dock") { model.unpin(item) }
        case .separator, .nowPlaying, .weather, .clock, .battery, .calendar, .runningApps, .keepAwake:
            EmptyView()
        }
    }
}

/// An item's own menu with the footer under it, as every tile that stands for an item shows it.
struct DockContextMenu: View {
    let item: DockItem
    let model: DockModel

    var body: some View {
        DockItemMenu(item: item, model: model)
        Divider()
        DockMenuFooter()
    }
}

/// The app's windows at the top of its menu, as the macOS Dock lists them; choosing one raises it.
/// Empty for a moment on the first open: the list is asked for as the menu is built and arrives
/// off the main thread — see `DockModel.requestMenuWindows`.
private struct AppWindowList: View {
    let pid: pid_t
    let model: DockModel

    var body: some View {
        // Only the first time: later opens ask from the controller, for the one menu opening. Asked on
        // every body run, each answer for one app re-ran every other built menu's list and asked its
        // app again.
        if model.menuWindows[pid] == nil {
            let _ = model.requestMenuWindows(for: pid)
        }
        if let listed = model.menuWindows[pid], !listed.windows.isEmpty {
            ForEach(listed.windows, id: \.id) { window in
                Button(window.title) { WindowActions.raise(window.id, pid: pid) }
            }
            Divider()
        }
    }
}

/// Options ▸ Open at Login and Assign To, as in the macOS Dock. Toggles rather than Buttons: in a
/// SwiftUI menu a Toggle is what draws the checkmark (measured in FinderPlus — checkmark images on
/// Buttons did not render). Read when the menu is built, since both live in macOS's own settings
/// and nothing announces a change to them — and built again on every open, through the item's
/// `model.menuOpens`, since SwiftUI would otherwise show the one it built last.
private struct AssignToMenu: View {
    let itemID: String
    let bundleID: String
    let app: URL
    /// The running app's, for the Desktops its windows are on.
    let pid: pid_t?
    let offersOpenAtLogin: Bool
    let model: DockModel

    var body: some View {
        let _ = model.menuOpens(of: itemID)
        let current = DesktopAssignments.assignment(of: bundleID)
        Menu("Options") {
            if offersOpenAtLogin {
                let opensAtLogin = LoginItems.opensAtLogin(app)
                Toggle("Open at Login", isOn: Binding(
                    get: { opensAtLogin },
                    set: { LoginItems.setOpensAtLogin(app, $0) }
                ))
            }
            Section("Assign To") {
                option("All Desktops", .allDesktops, current)
                ForEach(DesktopAssignments.desktopOptions(for: current, pid: pid), id: \.title) { desktop in
                    option(desktop.title, desktop.assignment, current)
                        .disabled(!desktop.isEnabled)
                }
                option("None", .none, current)
            }
        }
    }

    private func option(
        _ title: String, _ target: DesktopAssignments.Assignment, _ current: DesktopAssignments.Assignment
    ) -> some View {
        Toggle(title, isOn: Binding(
            get: { current == target },
            // Picking the ticked item again changes nothing.
            set: { on in
                if on, target != current { DesktopAssignments.assign(bundleID, to: target, title: title, app: app) }
            }
        ))
    }
}

/// Invisible, but draggable and removable — a gap the user placed. A divider is the same gap with
/// the separator's line drawn in it.
private struct SpacerTile: View {
    let item: DockItem
    let extent: CGFloat
    let iconSize: CGFloat
    let horizontal: Bool
    let model: DockModel

    @State private var isHovered = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            // Invisible until the pointer is on it: a gap that never announces itself, but can
            // still be found, grabbed and dragged.
            .fill(.primary.opacity(isHovered ? 0.12 : 0))
            .frame(width: horizontal ? extent : iconSize, height: horizontal ? iconSize : extent)
            .overlay {
                if item.id.hasPrefix(dividerPrefix) {
                    DividerLine(iconSize: iconSize, horizontal: horizontal)
                }
            }
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .contextMenu { DockContextMenu(item: item, model: model) }
            .onDrag {
                model.dragPayload(for: item)
            } preview: {
                // Dragging an invisible view drags an invisible image, which reads as a broken drag.
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.primary.opacity(0.25))
                    .frame(width: horizontal ? extent : iconSize, height: horizontal ? iconSize : extent)
            }
            .onDrop(of: DockModel.dropTypes, isTargeted: nil) { model.handleDrop($0, onto: item) }
            // An invisible gap, and nothing to press.
            .accessibilityHidden(true)
    }
}

/// A minimized window: its own snapshot, restored by a click — the real Dock's right side.
private struct MinimizedTile: View {
    let item: DockItem
    let extent: CGFloat
    let iconSize: CGFloat
    let horizontal: Bool
    let model: DockModel

    var body: some View {
        Group {
            if let windowID = item.windowID, let thumb = model.minimizedThumbs[windowID] {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                // The snapshot arrives late; until then, the owning app's icon marks the spot.
                Image(nsImage: model.icon(for: item))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .opacity(0.8)
            }
        }
        // `extent` runs along the bar, which is vertical on a side dock.
        .frame(width: horizontal ? extent : iconSize, height: horizontal ? iconSize : extent)
        .help(item.name)
        .contentShape(Rectangle())
        .onTapGesture { model.open(item) }
        .contextMenu { DockContextMenu(item: item, model: model) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.open(item) }
    }

    /// The window's title and whose it is — a title alone ("Untitled") says little.
    private var accessibilityLabel: String {
        ["Minimized window", item.name.isEmpty ? nil : item.name, item.appName].compactMap(\.self).joined(separator: ", ")
    }
}

/// The red count in an icon's corner, as the macOS Dock draws it: sized from the icon, never
/// narrower than a circle, and hanging a little past the corner.
private struct BadgeView: View {
    let text: String
    let iconSize: CGFloat

    var body: some View {
        let height = iconSize * 0.36
        Text(text)
            .font(.system(size: height * 0.62, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, height * 0.28)
            .frame(minWidth: height, minHeight: height)
            .background(Capsule().fill(.red))
            .fixedSize()
            .offset(x: height * 0.2, y: -height * 0.12)
    }
}

struct DockMenuFooter: View {
    var body: some View {
        // The macOS Dock's own wording, and the same setting as Settings ▸ General ▸ Visibility.
        Button(DockSettings.shared.autoHides ? "Turn Hiding Off" : "Turn Hiding On") {
            DockSettings.shared.autoHides.toggle()
        }
        // Worded to match, and the same setting as Settings ▸ Interactions ▸ Window previews.
        Button(DockSettings.shared.showsWindowPreviews ? "Turn Previews Off" : "Turn Previews On") {
            DockSettings.shared.showsWindowPreviews.toggle()
        }
        Divider()
        Button("DockPlus Settings…") { SettingsWindow.show() }
        Button("Quit DockPlus") { NSApp.terminate(nil) }
    }
}

@MainActor
private extension View {
    /// A widget tile's drag, to reorder it or take it off the bar, and the drop of anything onto it.
    func dockDraggable(_ item: DockItem, _ model: DockModel) -> some View {
        onDrag { model.dragPayload(for: item) }
            .onDrop(of: DockModel.dropTypes, isTargeted: nil) { model.handleDrop($0, onto: item) }
    }
}

private extension DockEdge {
    var alignment: Alignment {
        switch self {
        case .bottom: .bottomLeading
        case .left: .topLeading
        case .right: .topTrailing
        }
    }

    /// Where the along-axis offset is measured from: the strip's left end, or its top.
    var alongStart: Edge.Set { self == .bottom ? .leading : .top }

    var screenEdge: Edge.Set {
        switch self {
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }

    func hiddenOffset(_ distance: CGFloat) -> CGSize {
        switch self {
        case .bottom: CGSize(width: 0, height: distance)
        case .left: CGSize(width: -distance, height: 0)
        case .right: CGSize(width: distance, height: 0)
        }
    }

    /// Where the running dot sits: against the screen edge.
    var dotAlignment: Alignment {
        switch self {
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }

    var labelAlignment: Alignment {
        switch self {
        case .bottom: .top
        case .left: .trailing
        case .right: .leading
        }
    }
}
