import AppKit
import Carbon

/// What a global shortcut does. Each one can be changed or turned off in
/// Settings.
enum ShortcutAction: String, CaseIterable {
    case copyNewest
    case toggleStack

    var title: String {
        switch self {
        case .copyNewest: L("Copy newest card")
        case .toggleStack: L("Show or hide the stack")
        }
    }

    /// Option and Command: with Command no character is typed on any
    /// keyboard, and with no Control key a slip never reaches a terminal as
    /// Control-C.
    var standard: Shortcut {
        switch self {
        case .copyNewest: Shortcut(keyCode: kVK_ANSI_C, modifiers: optionKey | cmdKey, key: "C")
        case .toggleStack: Shortcut(keyCode: kVK_ANSI_T, modifiers: optionKey | cmdKey, key: "T")
        }
    }

    /// The shortcut set in Settings, the standard one until then, or nil once
    /// it is turned off.
    var shortcut: Shortcut? {
        get {
            guard let saved = UserDefaults.standard.dictionary(forKey: defaultsKey) else { return standard }
            return Shortcut(saved: saved)
        }
        nonmutating set {
            UserDefaults.standard.set(newValue?.saved ?? [:], forKey: defaultsKey)
        }
    }

    private var defaultsKey: String { "shortcut." + rawValue }
}

/// A key and its modifiers, as the Carbon hot key API registers them, with
/// the key's name as it was typed, to show it.
struct Shortcut: Equatable {
    let keyCode: UInt32
    /// Carbon flags: cmdKey, optionKey, controlKey, shiftKey.
    let modifiers: UInt32
    let key: String

    init(keyCode: Int, modifiers: Int, key: String) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = UInt32(modifiers)
        self.key = key
    }

    /// The keys just pressed. They must include Option or Control: Command
    /// and Shift alone belong to the apps' own shortcuts, and a key without
    /// modifiers would be taken away from typing.
    init?(event: NSEvent) {
        let flags = event.modifierFlags
        guard !flags.isDisjoint(with: [.option, .control]) else { return nil }
        var modifiers = 0
        if flags.contains(.command) { modifiers |= cmdKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        let typed = event.characters(byApplyingModifiers: [])?.uppercased() ?? ""
        let name = Shortcut.names[Int(event.keyCode)] ?? (typed.isEmpty ? "#\(event.keyCode)" : typed)
        self.init(keyCode: Int(event.keyCode), modifiers: modifiers, key: name)
    }

    init?(saved: [String: Any]) {
        guard let keyCode = saved["keyCode"] as? Int, let modifiers = saved["modifiers"] as? Int,
              let key = saved["key"] as? String else { return nil }
        self.init(keyCode: keyCode, modifiers: modifiers, key: key)
    }

    var saved: [String: Any] {
        ["keyCode": Int(keyCode), "modifiers": Int(modifiers), "key": key]
    }

    /// The same keys, whatever they were called when typed.
    static func == (a: Shortcut, b: Shortcut) -> Bool {
        a.keyCode == b.keyCode && a.modifiers == b.modifiers
    }

    /// Like ⌥⌘C: the modifiers in the order macOS shows them, then the key.
    var display: String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + key
    }

    /// Shows the shortcut next to a menu item. Keys with a longer name, like
    /// Space or F5, are left out there.
    func show(in item: NSMenuItem) {
        guard key.count == 1 else { return }
        item.keyEquivalent = key.lowercased()
        item.keyEquivalentModifierMask = flags
    }

    private var flags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    /// Keys that type nothing, or something hard to read.
    private static let names: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}
