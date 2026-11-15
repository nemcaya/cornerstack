import Carbon
import os

/// A global shortcut through the Carbon hot key API. Unlike a global key
/// monitor, it needs no Accessibility permission. One event handler serves
/// every shortcut and picks the action by the hot key's ID.
final class HotKey {
    private var ref: EventHotKeyRef?
    private let number: UInt32
    private static var actions: [UInt32: () -> Void] = [:]
    /// What to do when the key is let go, for the hot keys that care.
    private static var releases: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    /// Nil when macOS refuses the shortcut.
    init?(_ shortcut: Shortcut, action: @escaping () -> Void, released: (() -> Void)? = nil) {
        HotKey.installHandler()
        number = HotKey.nextID
        HotKey.nextID += 1
        let id = EventHotKeyID(signature: OSType(0x4353_544B), id: number) // "CSTK"
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            log.error("Could not register \(shortcut.display, privacy: .public): \(status, privacy: .public)")
            return nil
        }
        HotKey.actions[number] = action
        HotKey.releases[number] = released
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.actions[number] = nil
        HotKey.releases[number] = nil
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let number = id.id
            let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            DispatchQueue.main.async {
                if released { HotKey.releases[number]?() } else { HotKey.actions[number]?() }
            }
            return noErr
        }, specs.count, &specs, nil, nil)
    }
}
