import AppKit
import Carbon.HIToolbox
import os

/// App-wide global hot-keys via the Carbon Hot Key API.
///
/// `RegisterEventHotKey` is the standard way to capture a key combo no matter
/// which app is focused. Unlike an `NSEvent` global monitor it needs no
/// Accessibility permission AND actually swallows the event, so the focused
/// app (the terminal) never sees the keystroke.
@MainActor
final class GlobalHotKeys {
    struct Binding {
        let keyCode: UInt32
        let modifiers: UInt32
        let action: () -> Void
    }

    /// FourCharCode 'APHK' — namespaces our hot-key IDs.
    private static let signature: OSType = 0x4150_484B

    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handlerRef: EventHandlerRef?
    private var nextID: UInt32 = 1

    func register(_ bindings: [Binding]) {
        installHandlerIfNeeded()
        for binding in bindings {
            let id = nextID
            nextID += 1
            actions[id] = binding.action
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
            let status = RegisterEventHotKey(
                binding.keyCode, binding.modifiers, hotKeyID,
                GetApplicationEventTarget(), 0, &ref
            )
            if status == noErr {
                hotKeyRefs.append(ref)
            } else {
                actions[id] = nil
                Logger.app.error("Hot-key register failed (status \(status, privacy: .public))")
            }
        }
    }

    func unregisterAll() {
        for ref in hotKeyRefs where ref != nil { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
        actions.removeAll()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        // Non-capturing C callback — context comes through `userData`.
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                var hkID = EventHotKeyID()
                let err = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hkID
                )
                guard err == noErr else { return noErr }
                // Carbon delivers hot-key events on the main thread.
                let manager = Unmanaged<GlobalHotKeys>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { manager.fire(id: hkID.id) }
                return noErr
            },
            1, &eventType, userData, &handlerRef
        )
    }

    private func fire(id: UInt32) {
        actions[id]?()
    }
}
