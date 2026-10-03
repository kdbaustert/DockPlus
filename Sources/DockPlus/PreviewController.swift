import AppKit
import SwiftUI

/// The window-preview panel: rest the pointer on a running app and, after the configured delay,
/// thumbnails of its windows appear beside the dock. Fed by `DockController.tick`, which already
/// knows where the pointer is and which item it is over.
@MainActor
final class PreviewController {
    /// How long the pointer may be between the bar and the panel before the panel gives up. The gap
    /// is real: the name labels sit in it.
    private static let leaveGrace: TimeInterval = 0.35
    /// Switching between icons while the panel is already up ignores most of the dwell — as the
    /// Windows taskbar does, where only the first preview waits.
    private static let switchDelay: TimeInterval = 0.1
    private static let thumbHeight: CGFloat = 140

    private let settings: DockSettings
    private let panel = DockPopupPanel()
    private let host = FirstMouseHostingView(rootView: AnyView(EmptyView()))

    private var shownItemID: String?
    private var hoverItemID: String?
    /// The hovered item whose capture came back with nothing. Resting on it must not re-run the
    /// whole ScreenCaptureKit + AX + Spaces lookup every dwell period — Finder with no windows did.
    private var emptyItemID: String?
    private var hoverStart: Date?
    private var leftAt: Date?
    private var captureTask: Task<Void, Never>?
    private var refreshTimer: Timer?
    private var pointerInPanel = false
    /// The screen this dock lives on — where the panel must stay, whichever screen is "first".
    private weak var clampScreen: NSScreen?

    /// While the pointer is in the panel, the dock must not auto-hide under it.
    var keepsDockShown: Bool { panel.isVisible && pointerInPanel }
    /// Up, or on its way up: either way the dwell and the leave grace still run on the pointer ticks.
    var isActive: Bool { panel.isVisible || captureTask != nil || hoverStart != nil }

    init(settings: DockSettings) {
        self.settings = settings
        panel.contentView = host
    }

    /// One pointer tick. `center` is the hovered item's along-axis centre within the strip.
    func update(
        hovered: DockItem?, center: CGFloat?, mouse: NSPoint,
        dockFrame: NSRect, edge: DockEdge, barReach: CGFloat, isDockHidden: Bool,
        screen: NSScreen? = nil
    ) {
        clampScreen = screen
        guard settings.showsWindowPreviews, !isDockHidden else {
            hide()
            return
        }
        pointerInPanel = panel.isVisible && panel.frame.insetBy(dx: -8, dy: -8).contains(mouse)

        let eligible = hovered.flatMap { item -> DockItem? in
            item.kind == .app && item.isRunning && item.pid != nil ? item : nil
        }
        if let item = eligible, let center {
            leftAt = nil
            if item.id == shownItemID || item.id == emptyItemID { return }
            if item.id != hoverItemID {
                hoverItemID = item.id
                hoverStart = Date()
                emptyItemID = nil
            }
            let dwell = panel.isVisible ? min(settings.previewDelay, Self.switchDelay) : settings.previewDelay
            if let start = hoverStart, Date().timeIntervalSince(start) >= dwell {
                show(item, at: DockAnchor(center: center, dockFrame: dockFrame, edge: edge, barReach: barReach))
            }
        } else if pointerInPanel {
            leftAt = nil
        } else if panel.isVisible || captureTask != nil {
            // Not over an icon and not in the panel: a grace period covers the walk across the gap.
            if let left = leftAt {
                if Date().timeIntervalSince(left) > Self.leaveGrace { hide() }
            } else {
                leftAt = Date()
            }
        } else {
            hoverItemID = nil
            emptyItemID = nil
            hoverStart = nil
        }
    }

    func hide() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        captureTask?.cancel()
        captureTask = nil
        shownItemID = nil
        hoverItemID = nil
        emptyItemID = nil
        hoverStart = nil
        leftAt = nil
        pointerInPanel = false
        orderOutPanel()
    }

    private func orderOutPanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        // The thumbnails are the panel's biggest allocation; a dismissed panel keeps none.
        host.rootView = AnyView(EmptyView())
    }

    private func show(_ item: DockItem, at anchor: DockAnchor) {
        guard let pid = item.pid else { return }
        shownItemID = item.id

        guard WindowCapture.canCapture else {
            // The system prompt the first time; the pointer to Settings each time after.
            WindowCapture.askForPermissionOnce()
            if !WindowCapture.canCapture {
                present({ _ in PermissionStrip() }, at: anchor)
            }
            return
        }

        captureTask?.cancel()
        let scale = clampScreen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        captureTask = Task { [weak self] in
            let captured = await WindowCapture.thumbnails(pid: pid, maxHeight: Self.thumbHeight, scale: scale)
            guard let self, !Task.isCancelled, shownItemID == item.id else { return }
            captureTask = nil
            let thumbs = onThisDisplay(captured)
            guard !thumbs.isEmpty else {
                // Running, but nothing to show — a windowless agent, every capture came up blank, the
                // window list could not be read (`thumbnails` answers a thrown error with none), or
                // every window is on another display's dock.
                // Not `hide()`: that forgets the hover, and the next dwell would capture again.
                // The refresh timer goes, though: with the panel down it has nothing to refresh.
                refreshTimer?.invalidate()
                refreshTimer = nil
                emptyItemID = item.id
                shownItemID = nil
                leftAt = nil
                orderOutPanel()
                return
            }
            let raise: (CGWindowID) -> Void = { [weak self] id in
                WindowActions.raise(id, pid: pid)
                self?.hide()
            }
            let close: (CGWindowID) -> Void = { [weak self] id in
                WindowActions.close(id, pid: pid)
                // The window needs a moment to go; then what is left is re-captured.
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(450))
                    guard let self, shownItemID == item.id else { return }
                    shownItemID = nil
                    show(item, at: anchor)
                }
            }
            present({ width in
                PreviewStrip(
                    thumbs: thumbs, showsControls: settings.previewShowsControls, width: width,
                    raise: raise, close: close)
            }, at: anchor)
            startRefresh(item, at: anchor)
        }
    }

    /// Every thumbnail, unless each display's dock is to show only its own screen's windows. After
    /// the capture rather than before, from the frames that come back with it: filtering first would
    /// need the screen threaded into WindowCapture, to save only the other screens' captures.
    private func onThisDisplay(_ thumbs: [WindowThumb]) -> [WindowThumb] {
        guard settings.previewsShowOnlyThisDisplay, settings.displayMode == .all,
              let displayID = clampScreen?.displayID
        else { return thumbs }
        let display = CGDisplayBounds(displayID)
        return thumbs.filter { Self.isMostlyOn($0.frame, display: display) }
    }

    /// Whether more than half of `frame` lies on `display`, both in window-server coordinates (which
    /// is what `CGDisplayBounds` and ScreenCaptureKit's frames share). More than half, so a window
    /// straddling two screens shows on at most one dock — the one whose screen holds most of it.
    nonisolated static func isMostlyOn(_ frame: CGRect, display: CGRect) -> Bool {
        let area = frame.width * frame.height
        guard area > 0 else { return false }
        let overlap = frame.intersection(display)
        return !overlap.isNull && overlap.width * overlap.height > area / 2
    }

    /// "Live" previews: the open panel re-captures on a beat. Fresh screenshots rather than a video
    /// stream — a stream per window needs lifecycle the panel does not, and at this cadence the eye
    /// reads stills as live for anything but full-motion video.
    private func startRefresh(_ item: DockItem, at anchor: DockAnchor) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard settings.livePreviews else { return }
        let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Live previews turned off while the panel is up: stop now, not at the next hide.
                guard self.settings.livePreviews else {
                    self.refreshTimer?.invalidate()
                    self.refreshTimer = nil
                    return
                }
                guard self.panel.isVisible, self.shownItemID == item.id, self.captureTask == nil else { return }
                self.shownItemID = nil  // let show() run again for the same item
                self.show(item, at: anchor)
            }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    /// `make` is given the width to fit, nil for the view's own. Both are the same view type, so a
    /// strip that has to narrow is updated in place; swapping the root for a wrapper tore it down
    /// twice on every live refresh.
    private func present(_ make: (CGFloat?) -> some View, at anchor: DockAnchor) {
        host.rootView = AnyView(make(nil))
        let visible = (clampScreen ?? NSScreen.screens.first)?.visibleFrame
        var size = host.fittingSize
        // Enough windows outgrow the screen, and a panel wider than `visible` slid its left edge
        // off it. The thumbnails are flexible, so a narrower panel shrinks them to fit instead —
        // and, narrower, they are shorter: measured again at that width, or the strip sat centred
        // in a panel as tall as the full-width one, with a gap under it.
        if let visible, case let room = anchor.maxWidth(within: visible), size.width > room {
            host.rootView = AnyView(make(room))
            size = NSSize(width: room, height: host.fittingSize.height)
        }
        panel.setFrame(anchor.frame(for: size, within: visible), display: true)
        panel.orderFrontRegardless()
    }
}

/// The strip of thumbnails. Click one to jump to that window; the controls row adds each window's
/// title and a close button.
private struct PreviewStrip: View {
    let thumbs: [WindowThumb]
    let showsControls: Bool
    /// Narrower than the strip's own width when there are more windows than fit.
    let width: CGFloat?
    let raise: (CGWindowID) -> Void
    let close: (CGWindowID) -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(thumbs) { thumb in
                VStack(spacing: 5) {
                    if showsControls {
                        HStack(spacing: 6) {
                            Button {
                                close(thumb.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Close \(thumb.title)")
                            Text(thumb.title)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                    }
                    Image(decorative: thumb.image, scale: thumb.scale)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 220, maxHeight: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
                }
                // The thumbnail's own cap. Without it a long window title is what sizes the tile:
                // the Text's one-line ideal width is the whole title, and nothing above narrows it.
                .frame(maxWidth: 220)
                .contentShape(Rectangle())
                .onTapGesture { raise(thumb.id) }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(thumb.title)
                .accessibilityAddTraits(.isButton)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(4)
        .frame(width: width)
    }
}

/// Shown instead of thumbnails while Screen Recording is not granted.
private struct PermissionStrip: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Window previews need Screen Recording")
                .font(.system(size: 12, weight: .semibold))
            Text("Grant it to DockPlus in System Settings, then relaunch DockPlus.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("Open System Settings…") {
                NSWorkspace.shared.openPrivacyPane("ScreenCapture")
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(4)
    }
}
