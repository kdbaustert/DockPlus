import AppKit
import SwiftUI

struct AboutPane: View {
    private let updater = Updater.shared

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    var body: some View {
        SettingsPage(title: "About") {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 88, height: 88)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                    .padding(.bottom, 4)
                Text("DockPlus").font(.system(size: 24, weight: .bold))
                Text("A Dock replacement for macOS.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                // Markdown, so the name alone is the link and the sentence still reads as one line.
                Text("Created by [Kenny B](https://github.com/kdbaustert)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .tint(.accentColor)
                    .help("github.com/kdbaustert")
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .background(
                RoundedRectangle(cornerRadius: SettingsChrome.cardCorner, style: .continuous)
                    .fill(SettingsChrome.cardFill))
            .overlay(
                RoundedRectangle(cornerRadius: SettingsChrome.cardCorner, style: .continuous)
                    .strokeBorder(SettingsChrome.cardBorder, lineWidth: SettingsChrome.hairline))

            SettingsSection(
                title: "Updates", anchor: SettingsAnchor.updates,
                footer: Updater.isConfigured
                    ? "Updates come from GitHub releases and are checked against DockPlus's signing key before anything installs."
                    : "This is a local development build; it does not update itself."
            ) {
                SettingsRow(title: "Check for updates", subtitle: Self.lastCheckDescription(updater.lastCheck)) {
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheck || !Updater.isConfigured)
                }
                SettingsToggle(
                    title: "Check automatically",
                    subtitle: "Look for a new version about once a day, and say when there is one.",
                    isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 }))
                    .disabled(!Updater.isConfigured)
                SettingsToggle(
                    title: "Install automatically",
                    // The footer already covers a build with no feed; this covers the other reason
                    // the toggle is greyed out.
                    subtitle: "Download updates without asking and install them when DockPlus quits."
                        + (Updater.isConfigured && !updater.automaticallyChecks
                            ? " Needs the automatic check above." : ""),
                    isOn: Binding(get: { updater.automaticallyDownloads }, set: { updater.automaticallyDownloads = $0 }))
                    .disabled(!Updater.isConfigured || !updater.automaticallyChecks)
                SettingsToggle(
                    title: "Receive beta updates",
                    isOn: Binding(get: { UpdateChannels.receivesBetas }, set: { UpdateChannels.receivesBetas = $0 }))
                    .disabled(!Updater.isConfigured)
            }

            SettingsSection(title: "DockPlus", anchor: SettingsAnchor.build) {
                SettingsRow(title: "Version") {
                    Text(version)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                SettingsRow(title: "Source code", subtitle: "github.com/kdbaustert/DockPlus") {
                    Link("View on GitHub", destination: URL(string: "https://github.com/kdbaustert/DockPlus")!)
                }
                SettingsRow(title: "Quit DockPlus", subtitle: "Asks whether to bring the macOS Dock back first.") {
                    Button("Quit…") { NSApp.terminate(nil) }
                }
            }
        }
    }

    /// "Never checked." is shown rather than nothing: an updater that has never run is what this
    /// row is there to catch.
    private static func lastCheckDescription(_ date: Date?) -> String {
        guard let date else { return "Never checked." }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last checked \(formatter.localizedString(for: date, relativeTo: Date()))."
    }
}
