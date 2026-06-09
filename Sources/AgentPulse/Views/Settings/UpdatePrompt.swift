import AppKit
import SwiftUI

/// Presents the "update available" window. Built as a plain NSWindow (not a
/// SwiftUI scene) so it can be summoned from `AppState` and configured to
/// surface over the user's current Space — including a fullscreen app.
@MainActor
final class UpdatePromptPresenter {
    private var window: NSWindow?

    func show(_ update: AppUpdate, onSkip: @escaping (String) -> Void) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = UpdatePromptView(
            update: update,
            onDownload: { [weak self] in
                NSWorkspace.shared.open(update.pageURL)
                self?.close()
            },
            onSkip: { [weak self] in
                onSkip(update.version)
                self?.close()
            },
            onLater: { [weak self] in self?.close() }
        )

        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func close() {
        window?.close()
        window = nil
    }
}

private struct UpdatePromptView: View {
    let update: AppUpdate
    let onDownload: () -> Void
    let onSkip: () -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("A new version of \(AppInfo.displayName) is available")
                        .font(.system(size: 14, weight: .semibold))
                    Text("\(AppInfo.displayName) \(update.version) — you have \(AppInfo.version)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            if !update.notes.isEmpty {
                ScrollView {
                    Text(update.notes)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 150)
                .padding(10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Button("Skip This Version", action: onSkip)
                    .controlSize(.small)
                Spacer()
                Button("Later", action: onLater)
                Button("Download", action: onDownload)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
