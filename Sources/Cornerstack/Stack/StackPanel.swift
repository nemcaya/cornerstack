import AppKit

/// A transparent column along the right edge of the screen, above the Dock,
/// that floats over every app and every Space, full screen ones too unless
/// turned off in Settings. It never takes focus, and lets clicks pass through
/// everywhere except over the cards.
final class StackPanel: NSPanel {
    /// Called when the pointer moves over the panel or leaves it, which the
    /// panel only notices while it catches clicks, over a card. The rest is
    /// up to `AppDelegate.startMouseTracking`.
    var onPointerMove: () -> Void = {}

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
        // The stack sits in a container that watches the whole panel, so a
        // pointer leaving a card for the empty part of the column is noticed.
        let container = NSView()
        container.addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
        contentView = container
        content.frame = container.bounds
        content.autoresizingMask = [.width, .height]
        container.addSubview(content)
    }

    override func mouseMoved(with event: NSEvent) { onPointerMove() }
    override func mouseExited(with event: NSEvent) { onPointerMove() }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The stack sits on the screen you are using, which is the one with the
    /// pointer: that is where you just took the screenshot.
    static func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// A column as wide as the cards need, along the right edge of the
    /// screen's visible area, so it sits above the Dock.
    func placeOnScreen(_ screen: NSScreen, width: CGFloat) {
        let visible = screen.visibleFrame
        let target = NSRect(x: visible.maxX - width, y: visible.minY, width: width, height: visible.height)
        if frame != target { setFrame(target, display: true) }
    }
}
