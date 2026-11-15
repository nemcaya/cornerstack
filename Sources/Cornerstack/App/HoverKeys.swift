import AppKit
import Carbon

/// Single keys for the card under the pointer: C copies it, 1 copies it at
/// 1x, T copies its text, S shares it, R hides its secrets, L opens or copies its QR code, P
/// keeps it, Space opens Quick Look and Delete removes it.
///
/// They are Carbon hot keys, like the global shortcuts, so they need no
/// Accessibility permission. While they are on, those keys don't reach the
/// app you are typing in, so they are only taken while the pointer is on a
/// card, and they let go:
/// - after a key or a click on a card, until the pointer moves again: you
///   click a card, paste it into a chat and type without the letters going
///   to the card. The key that was pressed stays taken until it is let go,
///   so holding it down doesn't type into the app behind;
/// - when the pointer has rested for a few seconds, in case you start typing
///   with it parked on the stack.
/// Turn them off in Settings.
@MainActor
final class HoverKeys {
    enum Key: CaseIterable {
        case copy, copyAtOneX, copyText, share, hideSecrets, code, keep, quickLook, remove

        var keyCode: Int {
            switch self {
            case .copy: kVK_ANSI_C
            case .copyAtOneX: kVK_ANSI_1
            case .copyText: kVK_ANSI_T
            case .share: kVK_ANSI_S
            case .hideSecrets: kVK_ANSI_R
            case .code: kVK_ANSI_L
            case .keep: kVK_ANSI_P
            case .quickLook: kVK_Space
            case .remove: kVK_Delete
            }
        }

        /// The key's name, as `Shortcut` shows it.
        var name: String {
            switch self {
            case .copy: "C"
            case .copyAtOneX: "1"
            case .copyText: "T"
            case .share: "S"
            case .hideSecrets: "R"
            case .code: "L"
            case .keep: "P"
            case .quickLook: "Space"
            case .remove: "⌫"
            }
        }
    }

    private static let enabledKey = "hoverKeysOff"

    /// On until you turn them off in Settings.
    static var isEnabled: Bool {
        get { !UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(!newValue, forKey: enabledKey) }
    }

    /// How long the pointer may rest on a card before the keys let go.
    static let restLimit: TimeInterval = 6

    /// What a key does to a card; set by AppDelegate.
    var perform: (Key, UUID) -> Void = { _, _ in }

    private var hotKeys: [Key: HotKey] = [:]
    /// The key that just acted and is still down. Letting go of its hot key
    /// while it is held would send its repeats to the app you are typing in:
    /// a held Delete would remove the card and then your text.
    private var held: HotKey?
    private var heldTimer: Timer?
    /// The longest a key stays taken after it acted, however the keyboard
    /// says it is doing: a key must never be lost to typing for good.
    private static let heldLimit: TimeInterval = 30
    private var card: UUID?
    /// Where the pointer was when the keys paused, after a key or a click.
    /// They come back once it moves away from there.
    private var pausedAt: CGPoint?
    private var restTimer: Timer?
    /// When the pointer last moved. Only a move turns the keys on, so while
    /// they are on this is always up to date.
    private var lastMove = Date.distantPast
    private var sinceLastMove: TimeInterval { Date().timeIntervalSince(lastMove) }

    /// The card under the pointer, or nil. Called whenever the pointer moves
    /// (`moved`) or the cards move under it.
    ///
    /// Only a move of the pointer onto a card turns the keys on. A card that
    /// lands, slides back or moves up under a resting pointer doesn't: you
    /// may be typing, with the pointer parked where the new card appeared.
    func update(card newCard: UUID?, moved: Bool) {
        let point = NSEvent.mouseLocation
        if moved { lastMove = Date() }
        if let paused = pausedAt, hypot(point.x - paused.x, point.y - paused.y) > 3 { pausedAt = nil }
        if !moved && newCard != card {
            card = nil
            setArmed(false)
            return
        }
        card = newCard
        let resting = sinceLastMove >= Self.restLimit
        setArmed(Self.isEnabled && newCard != nil && pausedAt == nil && !resting && (moved || !hotKeys.isEmpty))
    }

    /// A click on a card: the keys wait until the pointer moves.
    func pause() {
        pausedAt = NSEvent.mouseLocation
        setArmed(false)
    }

    /// No card to point at: the stack is hidden, tucked away or a card is
    /// being dragged.
    func stop() {
        card = nil
        setArmed(false)
    }

    private func setArmed(_ on: Bool) {
        if on { watchRest() }
        guard on == hotKeys.isEmpty else { return }
        if on {
            // A key still held from before is taken again with the others.
            release()
            for key in Key.allCases {
                hotKeys[key] = HotKey(Shortcut(keyCode: key.keyCode, modifiers: 0, key: key.name),
                                      action: { [weak self] in self?.pressed(key) },
                                      released: { [weak self] in self?.release() })
            }
        } else {
            // Letting go of a hot key unregisters it.
            hotKeys = [:]
            restTimer?.invalidate()
            restTimer = nil
        }
    }

    private func pressed(_ key: Key) {
        guard !hotKeys.isEmpty, let card else { return }
        // Every key pauses the keys, so typing that starts right after can't
        // go to the card. The key itself stays taken while it is down.
        hold(hotKeys.removeValue(forKey: key), code: key.keyCode)
        pause()
        perform(key, card)
    }

    private func hold(_ key: HotKey?, code: Int) {
        release()
        held = key
        guard key != nil else { return }
        // Its release normally says when it is let go. In case that never
        // arrives, the keyboard is asked twice a second whether the key is
        // still down, which needs no permission.
        let since = Date()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                let down = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code))
                if !down || Date().timeIntervalSince(since) > Self.heldLimit { self?.release() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        heldTimer = timer
    }

    /// The held key was let go, or was held long enough: it is free again.
    private func release() {
        heldTimer?.invalidate()
        heldTimer = nil
        held = nil
    }

    /// One timer at a time: when it fires before the pointer has rested long
    /// enough, it waits for the rest.
    private func watchRest() {
        guard restTimer == nil else { return }
        let remaining = Self.restLimit - sinceLastMove
        let timer = Timer(timeInterval: max(0.2, remaining), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.restTimer = nil
                if self.sinceLastMove >= Self.restLimit {
                    self.setArmed(false)
                } else if !self.hotKeys.isEmpty {
                    self.watchRest()
                }
            }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        restTimer = timer
    }
}
