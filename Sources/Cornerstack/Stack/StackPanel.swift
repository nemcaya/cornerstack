import AppKit

/// A transparent column along the right edge of the screen, above the Dock,
/// that floats over every app and every Space, full screen ones too unless
/// turned off in the menu. It never takes focus, and lets clicks pass through
/// everywhere except over the cards.
final class StackPanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Keep the stack out of new screenshots and recordings.
        sharingType = .none
        level = .statusBar
        // Every Space, full screen ones included. Whether the stack shows over
        // a full screen app is up to the user, see FullScreen.showOverFullScreen.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The stack sits on the screen you are using, which is the one with the
    /// pointer: that is where you just took the screenshot.
    static func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    func placeOnScreen(_ screen: NSScreen? = nil) {
        guard let visible = (screen ?? StackPanel.screenUnderPointer())?.visibleFrame else { return }
        let target = NSRect(x: visible.maxX - Layout.panelWidth, y: visible.minY,
                            width: Layout.panelWidth, height: visible.height)
        if frame != target { setFrame(target, display: true) }
    }
}
