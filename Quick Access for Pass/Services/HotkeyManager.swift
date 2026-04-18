import AppKit
import Carbon

/// Global hotkey manager using the Carbon Event API.
///
/// **Lifetime assumption:** This class must live for the entire app lifetime (owned by AppDelegate).
/// The Carbon event handler stores a raw `Unmanaged` pointer to `self`; if the instance were
/// deallocated while the handler is still installed, the callback would dereference freed memory.
/// Because AppDelegate owns the sole instance and never releases it before termination, this is safe.
@MainActor
final class HotkeyManager {
    // nonisolated(unsafe) so deinit can access these Carbon refs without main-actor isolation.
    // Safe because all writes happen on the main actor, and deinit runs after the last reference
    // is released, guaranteeing no concurrent writes are possible.
    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var handlerRef: EventHandlerRef?
    private var onTrigger: (@Sendable () -> Void)?
    private var lastKeyCode: UInt16 = 0
    private var lastModifiers: UInt = 0

    /// The current shortcut. Default: Shift+Option+Space
    var keyCode: UInt16 = 49  // Space
    var modifiers: NSEvent.ModifierFlags = [.shift, .option]

    /// Registers the hotkey, skipping re-registration if the key and modifiers are unchanged.
    func register(handler: @escaping @Sendable () -> Void) {
        let newCode = keyCode
        let newMods = modifiers.rawValue
        if newCode == lastKeyCode && newMods == lastModifiers && onTrigger != nil {
            return
        }
        lastKeyCode = newCode
        lastModifiers = newMods

        unregister()
        self.onTrigger = handler

        // Use Carbon API for reliable global hotkey
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x50515141) // "PQQA"
        hotKeyID.id = 1

        let carbonModifiers: UInt32 = carbonFlags(from: modifiers)

        RegisterEventHotKey(
            UInt32(keyCode),
            carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        installCarbonHandler()
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let ref = handlerRef {
            RemoveEventHandler(ref)
            handlerRef = nil
        }
        onTrigger = nil
    }

    private func installCarbonHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                // Main-thread assumption: Carbon hotkey events have always been
                // delivered on the main thread since the API was introduced, and
                // this has never changed. We rely on that invariant to call
                // `manager.onTrigger?()` (which may touch @MainActor state)
                // directly from this @convention(c) callback without a
                // DispatchQueue.main.async hop. If Apple ever changes Carbon's
                // dispatch thread, this will become a data race — add the hop
                // at that point.
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated {
                    manager.onTrigger?()
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &handlerRef
        )
    }

    private func carbonFlags(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        return result
    }

    deinit {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = handlerRef { RemoveEventHandler(ref) }
    }
}
