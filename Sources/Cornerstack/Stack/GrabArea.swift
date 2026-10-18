import AppKit
import SwiftUI

/// Bridges each card to AppKit's drag and drop, so it can be dragged into
/// any app as a real file. Each destination means one thing:
///
/// - An app gets a copy, and the card leaves the stack unless it is kept
///   (the file stays).
/// - A folder or the Desktop keeps the file, and the card leaves the stack.
/// - The Trash takes the file.
/// - Nowhere that accepts it: the card flies back to the stack.
///
/// Click copies, Option-click copies the path, press and hold opens Markup,
/// a force click opens Quick Look. The cross in the top left corner takes the
/// card off the stack; the pin in the top right keeps it there.
struct GrabArea: NSViewRepresentable {
    let item: Shot
    let stack: Stack

    func makeNSView(context: Context) -> GrabView {
        let view = GrabView()
        configure(view)
        return view
    }

    func updateNSView(_ view: GrabView, context: Context) {
        configure(view)
    }

    private func configure(_ view: GrabView) {
        let id = item.id
        let stack = stack
        let isRecording = item.isRecording
        view.url = item.url
        view.dragImage = item.thumb
        view.kept = item.kept
        let kept = item.kept
        view.onClick = { stack.copy(id) }
        view.onOptionClick = { stack.copyPath(id) }
        view.onDoubleClick = { stack.open(id) }
        view.onForceClick = { stack.quickLook(id) }
        view.onDragStart = { stack.draggingID = id }
        view.onDragEnd = {
            stack.draggingID = nil
            // Moved into a folder: it is saved where you wanted it.
            stack.prune()
        }
        view.onTrash = { stack.trash(id) }
        view.onDropIntoApp = { stack.dropUnlessKept(id) }
        view.onRemove = { stack.drop(id) }
        view.onTogglePin = { stack.toggleKeep(id) }
        view.onLongPress = { stack.markup(id) }
        view.onPressChange = { pressed in stack.pressedID = pressed ? id : nil }
        view.menuProvider = {
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem(L("Copy")) { stack.copy(id) })
            if !isRecording {
                menu.addItem(ClosureMenuItem(L("Copy Text")) { stack.copyText(id) })
            }
            menu.addItem(ClosureMenuItem(L("Copy Path")) { stack.copyPath(id) })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(L("Open")) { stack.open(id) })
            menu.addItem(ClosureMenuItem(L("Quick Look")) { stack.quickLook(id) })
            // Recordings open in the trimming editor instead of Markup.
            menu.addItem(ClosureMenuItem(isRecording ? L("Trim") : L("Markup")) { stack.markup(id) })
            menu.addItem(ClosureMenuItem(L("Show in Finder")) { stack.showInFinder(id) })
            if stack.isInInbox(id) {
                menu.addItem(ClosureMenuItem(L("Save to Desktop")) { stack.saveToDesktop(id) })
            }
            menu.addItem(.separator())
            let keep = ClosureMenuItem(L("Keep on stack")) { stack.toggleKeep(id) }
            keep.state = kept ? .on : .off
            menu.addItem(keep)
            menu.addItem(ClosureMenuItem(L("Remove from stack")) { stack.drop(id) })
            menu.addItem(ClosureMenuItem(L("Move to Trash")) { stack.trash(id) })
            return menu
        }
    }
}

final class GrabView: NSView, NSDraggingSource {
    static var isDragging = false

    var url: URL?
    var dragImage: NSImage?
    /// A kept card has no cross: its top left corner doesn't remove it.
    var kept = false
    var onClick: () -> Void = {}
    var onOptionClick: () -> Void = {}
    var onDoubleClick: () -> Void = {}
    var onForceClick: () -> Void = {}
    var onDragStart: () -> Void = {}
    var onDragEnd: () -> Void = {}
    var onTrash: () -> Void = {}
    var onDropIntoApp: () -> Void = {}
    var onRemove: () -> Void = {}
    var onTogglePin: () -> Void = {}
    var onLongPress: () -> Void = {}
    var onPressChange: (Bool) -> Void = { _ in }
    var menuProvider: () -> NSMenu = { NSMenu() }

    private var downPoint: NSPoint?
    private var startedDrag = false
    private var holdTimer: Timer?
    private var didLongPress = false

    /// How long you hold before Markup opens. Long enough not to fire on a
    /// slow click, short enough to feel deliberate.
    private static let holdDuration: TimeInterval = 0.45

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The cross and the pin drawn in the top corners of the card. They are
    /// handled here because this view sits on top of the SwiftUI card.
    static let cornerHitSize: CGFloat = 26

    private enum Corner { case left, right }

    private func corner(of event: NSEvent) -> Corner? {
        let p = convert(event.locationInWindow, from: nil)
        let y = isFlipped ? 0 : bounds.height - Self.cornerHitSize
        let size = Self.cornerHitSize
        if NSRect(x: 0, y: y, width: size, height: size).contains(p) { return .left }
        if NSRect(x: bounds.width - size, y: y, width: size, height: size).contains(p) { return .right }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        switch corner(of: event) {
        case .left? where !kept:
            downPoint = nil
            onRemove()
            return
        case .right?:
            downPoint = nil
            onTogglePin()
            return
        default:
            break
        }
        if event.clickCount == 2 {
            downPoint = nil
            onDoubleClick()
            return
        }
        downPoint = event.locationInWindow
        startedDrag = false
        didLongPress = false
        onPressChange(true)
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.downPoint != nil, !self.startedDrag else { return }
                self.didLongPress = true
                self.onPressChange(false)
                self.onLongPress()
            }
        }
    }

    /// A force click on a trackpad opens Quick Look, as it does in Finder.
    /// It counts instead of the click and of a long press.
    override func pressureChange(with event: NSEvent) {
        guard event.stage == 2, downPoint != nil, !startedDrag, !didLongPress else { return }
        didLongPress = true
        endPress()
        onForceClick()
    }

    private func endPress() {
        holdTimer?.invalidate()
        holdTimer = nil
        onPressChange(false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, !startedDrag, let url else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4, !didLongPress else { return }
        startedDrag = true
        endPress()

        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(imageFrame(), contents: dragImage)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        // Released where nothing accepts it: the card flies back to the stack.
        session.animatesToStartingPositionsOnCancelOrFail = true
        GrabView.isDragging = true
        onDragStart()
    }

    override func mouseUp(with event: NSEvent) {
        endPress()
        if downPoint != nil && !startedDrag && !didLongPress && event.clickCount == 1 {
            if event.modifierFlags.contains(.option) { onOptionClick() } else { onClick() }
        }
        downPoint = nil
        didLongPress = false
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(menuProvider(), with: event, for: self)
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Apps pick copy. Finder picks move, so a folder or the Desktop keeps
        // the file. Delete is what lets the Dock's Trash accept it.
        context == .outsideApplication ? [.copy, .move, .delete] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        GrabView.isDragging = false
        startedDrag = false
        downPoint = nil
        log.notice("Drag ended with operation \(operation.rawValue, privacy: .public)")
        // Dropped on the Trash: macOS only tells us, we move the file.
        if operation.contains(.delete) {
            onDragEnd()
            onTrash()
            return
        }
        // Dropped into an app: it has its copy, so the card leaves the stack.
        // The file stays put, in case the app reads it a moment later.
        if operation.contains(.copy) {
            onDragEnd()
            onDropIntoApp()
            return
        }
        onDragEnd()
        // Finder finishes a move a moment later. Check again then, so a card
        // saved into a folder leaves the stack.
        if operation.contains(.move) {
            let done = onDragEnd
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { done() }
        }
    }

    /// The drag preview keeps the photo's aspect ratio inside the card.
    private func imageFrame() -> NSRect {
        guard let size = dragImage?.size, size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }
}
