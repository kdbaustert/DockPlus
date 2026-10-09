import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Panes

/// Both readable without prompting; re-read on a slow beat while the pane is up, so granting in
/// System Settings shows here without restarting anything.
private struct PermissionsState: Equatable {
    var screenRecording = CGPreflightScreenCaptureAccess()
    var accessibility = AXIsProcessTrusted()
}

private struct PermissionRow: View {
    let title: String
    let granted: Bool
    /// The Privacy & Security pane the button opens, named by what follows "Privacy_".
    let pane: String

    var body: some View {
        SettingsRow(title: title) {
            HStack(spacing: 8) {
                Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(granted ? .green : .orange)
                Text(granted ? "Granted" : "Not granted")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if !granted {
                    Button("Open System Settings…") {
                        NSWorkspace.shared.openPrivacyPane(pane)
                    }
                }
            }
        }
    }
}

struct GeneralPane: View {
    @Bindable var settings: DockSettings
    @State private var permissions = PermissionsState()
    @State private var opensAtLogin = GeneralPane.registeredAtLogin
    @State private var needsLoginApproval = SMAppService.mainApp.status == .requiresApproval
    @State private var loginError: String?
    /// Set while a failed change puts the toggle back, so that `onChange` does not answer the reset by
    /// trying the opposite change and replacing the real error with its own.
    @State private var isResettingLogin = false

    var body: some View {
        SettingsPage(title: "General", subtitle: "How DockPlus starts, and what it does with the macOS Dock.") {
            SettingsSection(title: "Startup", anchor: SettingsAnchor.startup, footer: loginError) {
                SettingsToggle(
                    title: "Show menu-bar icon",
                    subtitle: "Off leaves no menu-bar item. Right-click the dock to get Settings back.",
                    isOn: $settings.showsMenuBarIcon)
                SettingsToggle(title: "Start at login", isOn: $opensAtLogin)
                if needsLoginApproval {
                    SettingsRow(title: "Login Items", subtitle: "DockPlus is turned off in System Settings, so it won't start at login.") {
                        Button("Open System Settings…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            }
            SettingsSection(
                title: "macOS Dock",
                anchor: SettingsAnchor.macOSDock,
                footer: "When you quit DockPlus, it asks whether to bring the macOS Dock back."
            ) {
                SettingsToggle(
                    title: "Hide the macOS Dock",
                    subtitle: "It keeps running for the app switcher, Mission Control and Spaces — just out of sight.",
                    isOn: $settings.hidesSystemDock)
                SettingsToggle(
                    title: "Let apps bounce for attention",
                    subtitle: "An app that needs you pops its icon up from the screen edge, beneath DockPlus.",
                    isOn: $settings.systemDockBouncesForAttention)
                    .disabled(!settings.hidesSystemDock)
            }
            SettingsSection(
                title: "Display", anchor: SettingsAnchor.display,
                footer: NSScreen.screens.count > 1
                    ? nil : "One screen is attached right now; these take effect when more are."
            ) {
                SettingsChoice(
                    title: "Show the dock on",
                    selection: $settings.displayMode,
                    options: [
                        .init(value: .followPointer, title: "Follow the pointer", symbol: "cursorarrow.motionlines"),
                        .init(value: .primary, title: "Primary display", symbol: "menubar.dock.rectangle"),
                        .init(value: .specific, title: "A specific display", symbol: "1.square"),
                        .init(value: .all, title: "All displays", symbol: "rectangle.on.rectangle"),
                    ])
                if settings.displayMode == .specific {
                    SettingsRow(title: "Display") {
                        Picker("", selection: $settings.specificDisplay) {
                            ForEach(NSScreen.screens, id: \.displayUUID) { screen in
                                Text(screen.localizedName).tag(screen.displayUUID ?? "")
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                        // Nothing chosen yet matches no tag, and the picker shows blank — while the
                        // dock itself already sits on the first screen, the fallback it uses.
                        .onAppear {
                            if settings.specificDisplay.isEmpty,
                               let first = NSScreen.screens.first?.displayUUID {
                                settings.specificDisplay = first
                            }
                        }
                    }
                }
            }
            SettingsSection(
                title: "Permissions", anchor: SettingsAnchor.permissions,
                footer: "Previews picture other apps' windows (Screen Recording); restoring and closing windows steers them, and app badges are read from the macOS Dock (Accessibility)."
            ) {
                PermissionRow(
                    title: "Screen Recording", granted: permissions.screenRecording,
                    pane: "ScreenCapture")
                PermissionRow(
                    title: "Accessibility", granted: permissions.accessibility,
                    pane: "Accessibility")
            }
            SettingsSection(
                title: "Updates", anchor: SettingsAnchor.updates,
                footer: Updater.isConfigured
                    ? "Updates come from GitHub releases. Check from the menu bar icon."
                    : "This is a local development build; it does not update itself."
            ) {
                SettingsToggle(
                    title: "Receive beta updates",
                    isOn: Binding(get: { UpdateChannels.receivesBetas }, set: { UpdateChannels.receivesBetas = $0 }))
                    .disabled(!Updater.isConfigured)
            }
            SettingsSection(
                title: "iCloud", anchor: SettingsAnchor.iCloud,
                footer: SettingsSync.isAvailable
                    ? "Every Mac signed in to your iCloud account with this on shares one set of settings, kept in iCloud Drive ▸ DockPlus. Hiding the macOS Dock stays per Mac."
                    : "iCloud Drive isn't turned on for this Mac. Turn it on in System Settings ▸ Apple Account ▸ iCloud."
            ) {
                SettingsToggle(
                    title: "Sync settings with iCloud",
                    // A failed write says so here; it used to reach only the log.
                    subtitle: SettingsSync.current?.lastError.map { "Last sync failed: \($0)" }
                        ?? "Nearly every setting — appearance, behavior, widgets, pinned apps and stacks. Display choices stay on each Mac.",
                    isOn: $settings.syncsWithICloud)
                    .disabled(!SettingsSync.isAvailable)
            }
            SettingsSection(title: "Backup", anchor: SettingsAnchor.backup) {
                SettingsRow(title: "Settings file", subtitle: "Move your whole setup between Macs, or keep a copy.") {
                    HStack(spacing: 8) {
                        Button("Export…") { SettingsFile.export(settings) }
                        Button("Import…") { SettingsFile.importInto(settings) }
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                permissions = PermissionsState()
                // Removed in System Settings ▸ Login Items while this is open, the switch would stay
                // on and its next click would unregister an item that is gone.
                let enabled = Self.registeredAtLogin
                if enabled != opensAtLogin {
                    isResettingLogin = true
                    opensAtLogin = enabled
                }
                needsLoginApproval = SMAppService.mainApp.status == .requiresApproval
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onChange(of: opensAtLogin) { _, on in
            if isResettingLogin {
                isResettingLogin = false
                return
            }
            setOpensAtLogin(on)
        }
    }

    /// Registered counts even while awaiting approval: the user asked for it, and reading that as off
    /// flipped the switch back by itself.
    private static var registeredAtLogin: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    private func setOpensAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
            needsLoginApproval = SMAppService.mainApp.status == .requiresApproval
        } catch {
            loginError = error.localizedDescription
            let enabled = Self.registeredAtLogin
            if enabled != opensAtLogin {
                isResettingLogin = true
                opensAtLogin = enabled
            }
        }
    }
}
