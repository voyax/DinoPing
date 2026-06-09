import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let appState: AppState

    var body: some View {
        TabView {
            GeneralSettings(appState: appState)
                .tabItem { Label("General", systemImage: "gearshape") }
            ShortcutSettings()
                .tabItem { Label("Shortcuts", systemImage: "command") }
            AboutSettings(appState: appState)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480)
        .frame(minHeight: 300)
        // Without this, an `.accessory` app's Settings window opens on the
        // desktop Space — invisible when the user is in a fullscreen app. Pull
        // it onto whatever Space is active (incl. a fullscreen one) and front.
        .background(ActiveSpaceWindowConfigurator())
    }
}

/// Configures the hosting window to surface over the current Space — including
/// another app's fullscreen Space — and brings it to the front. Mirrors the
/// notch panel's collection behavior so Settings shows up where the user is.
private struct ActiveSpaceWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    let appState: AppState

    @AppStorage("soundEnabled") private var soundEnabled = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var displaySelection = DisplayPreference.preferredName ?? autoTag
    @State private var launchError: String?

    private static let autoTag = "__auto__"

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let launchError {
                    Text(launchError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Notifications") {
                Toggle("Play sounds", isOn: $soundEnabled)
                Text("Permission requests, completions, and errors play a system sound.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Display") {
                Picker("Show notch on", selection: $displaySelection) {
                    Text("Automatic").tag(Self.autoTag)
                    ForEach(NSScreen.screens, id: \.localizedName) { screen in
                        Text(screen.localizedName).tag(screen.localizedName)
                    }
                }
                .onChange(of: displaySelection) { _, sel in
                    appState.notchPanel?.applyDisplayPreference(sel == Self.autoTag ? nil : sel)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchError = nil
        } catch {
            // Revert the toggle to reflect the real state and explain why.
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchError = "Couldn't update login item — needs a signed app build."
        }
    }
}

// MARK: - About

private struct AboutSettings: View {
    let appState: AppState
    @State private var showWhatsNew = false
    @State private var showLicense = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 76, height: 76)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            VStack(spacing: 3) {
                Text(AppInfo.displayName)
                    .font(.system(size: 17, weight: .semibold))
                Text("Version \(AppInfo.version) (\(AppInfo.build))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("Monitor your AI agents from the notch.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button("What's New") { showWhatsNew = true }
                Button("License") { showLicense = true }
                if let website = AppInfo.websiteURL {
                    Link("Website", destination: website)
                }
                if let issues = AppInfo.issuesURL {
                    Link("Report an Issue", destination: issues)
                }
            }
            .controlSize(.small)

            updateStatus

            Text(AppInfo.copyright)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .sheet(isPresented: $showWhatsNew) { WhatsNewSheet() }
        .sheet(isPresented: $showLicense) { LicenseSheet() }
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch appState.updateChecker.status {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking for updates…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .upToDate:
            HStack(spacing: 8) {
                Text("You're up to date.").font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Check Again") { check() }.controlSize(.small)
            }
        case .available(let update):
            HStack(spacing: 8) {
                Text("Version \(update.version) is available")
                    .font(.system(size: 11, weight: .medium))
                Button("Download") { NSWorkspace.shared.open(update.pageURL) }
                    .controlSize(.small)
            }
        case .failed(let message):
            HStack(spacing: 8) {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Try Again") { check() }.controlSize(.small)
            }
        case .idle:
            Button("Check for Updates…") { check() }.controlSize(.small)
        }
    }

    private func check() {
        Task { await appState.updateChecker.check() }
    }
}

private struct WhatsNewSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("What's New").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(ReleaseNotes.all) { note in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(note.version).font(.system(size: 13, weight: .semibold))
                                Text(note.date).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            ForEach(note.highlights, id: \.self) { line in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("•").foregroundStyle(.secondary)
                                    Text(line).font(.system(size: 12))
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
        .frame(width: 380, height: 320)
    }
}

private struct LicenseSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("License").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(16)
            Divider()
            ScrollView {
                Text(AppInfo.licenseText)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .frame(width: 380, height: 260)
    }
}

// MARK: - Shortcuts

private struct ShortcutSettings: View {
    @State private var settings = HotKeySettings.shared
    @State private var conflictMessage: String?

    var body: some View {
        Form {
            Section {
                ForEach(HotKeyAction.allCases) { action in
                    row(for: action)
                }
            } header: {
                Text("Global Shortcuts")
            } footer: {
                if let conflictMessage {
                    Text(conflictMessage)
                        .font(.caption)
                        .foregroundStyle(Color(.systemRed))
                } else {
                    Text("Work from any app. Click a shortcut to rebind it; Escape cancels.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func row(for action: HotKeyAction) -> some View {
        let combo = settings.combo(for: action)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(action.title).font(.system(size: 13))
                Text(action.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !settings.isDefault(action) {
                Button {
                    settings.reset(action)
                    conflictMessage = nil
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Reset to default")
            }
            HotKeyRecorderField(combo: combo) { capture($0, for: action) }
        }
        .padding(.vertical, 2)
    }

    private func capture(_ combo: HotKeyCombo, for action: HotKeyAction) {
        if let other = settings.conflict(for: combo, excluding: action) {
            conflictMessage = "\(combo.display) is already used by “\(other.title)”."
            NSSound.beep()
            return
        }
        conflictMessage = nil
        settings.set(combo, for: action)
    }
}
