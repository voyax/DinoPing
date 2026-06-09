import AppKit
import SwiftUI

/// A click-to-record shortcut field. Clicking arms it; the next key combo with
/// at least one of ⌘/⌥/⌃ is captured, Escape cancels, a bare key beeps.
struct HotKeyRecorderField: View {
    let combo: HotKeyCombo
    let onCapture: (HotKeyCombo) -> Void
    @State private var recording = false

    var body: some View {
        Button {
            recording.toggle()
        } label: {
            Text(recording ? "Press shortcut…" : combo.display)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(recording ? Color.accentColor : .primary)
                .frame(minWidth: 104)
        }
        .buttonStyle(.bordered)
        .overlay {
            if recording {
                // Click-through capture layer active only while recording.
                KeyCapture(
                    onCapture: { recording = false; onCapture($0) },
                    onCancel: { recording = false }
                )
            }
        }
    }
}

private struct KeyCapture: NSViewRepresentable {
    let onCapture: (HotKeyCombo) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install(onCapture: onCapture, onCancel: onCancel)
        return PassthroughView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        MainActor.assumeIsolated { coordinator.remove() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Lets clicks fall through to the button beneath, so clicking the field
    /// again toggles recording off.
    final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor
    final class Coordinator {
        private var monitor: Any?

        func install(onCapture: @escaping (HotKeyCombo) -> Void, onCancel: @escaping () -> Void) {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
                if event.keyCode == 0x35 { // Escape
                    onCancel()
                    return nil
                }
                let mods = HotKeyCombo.carbonModifiers(from: event.modifierFlags)
                let combo = HotKeyCombo(keyCode: UInt32(event.keyCode), carbonModifiers: mods)
                guard combo.hasRequiredModifier else {
                    NSSound.beep()
                    return nil
                }
                onCapture(combo)
                return nil // swallow so the key doesn't reach the field
            }
        }

        func remove() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
