import AppKit
import Combine
import Quartz
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let stack = Stack()
    private var panel: StackPanel!
    private var statusItem: NSStatusItem!
    private var watcher: ScreenshotWatcher!
    /// In inbox mode, a second watcher on the Desktop. If a macOS version
    /// ignores the screenshot settings (macOS 27 renamed one), captures keep
    /// landing on the Desktop, and they still land on the stack.
    private var safetyWatcher: ScreenshotWatcher?
    private var clipboardWatcher: ClipboardWatcher!
    private var signalSources: [DispatchSourceSignal] = []
    private var hotKeys: [HotKey] = []
    private let settingsWindow = SettingsWindow()
    private lazy var settings = SettingsModel(actions: .init(
        applyCardWidth: { [weak self] fitting in self?.placePanel(on: self?.panel.screen, fitting: fitting) },
        automaticWidth: { [weak self] in
            CardWidth.automatic(for: (self?.panel.screen ?? StackPanel.screenUnderPointer())?.visibleFrame ?? .zero)
        },
        setInbox: { [weak self] on in self?.setInbox(on) },
        setClipboard: { [weak self] on in self?.setClipboard(on) },
        setOverFullScreen: { [weak self] on in
            FullScreen.showOverFullScreen = on
            self?.refresh()
        },
        setSounds: { [weak self] on in self?.stack.soundOn = on },
        setOpenAtLogin: { on in AppDelegate.setOpenAtLogin(on) },
        registerShortcuts: { [weak self] paused in self?.registerShortcuts(paused: paused) ?? [] }
    ))
    private var cancellables = Set<AnyCancellable>()
    /// Report pointer moves while the stack shows; see `startMouseTracking`.
    private var mouseMonitors: [Any] = []
    private var activeTimer: Timer?
    /// New captures are decoded here, one at a time, so they land in the
    /// order they were taken.
    private let decoder = DispatchQueue(label: "io.github.nemcaya.cornerstack.decode", qos: .userInitiated)

    /// Whether the panel may be on screen: there is something to show and no
    /// full screen app in the way.
    private var isPresent = false
    /// Whether the stack is showing. It stays until every card is dealt
    /// with, or until you hide it with the shortcut or the menu.
    private var isShown = false
    /// Hidden with the shortcut or the menu while it still had cards. It
    /// stays hidden until you show it again or take a new screenshot.
    private var hiddenByUser = false
    private var staleStateSince: Date?
    /// Whether the stack should be up, if nothing prevents it. With "Show
    /// over full screen apps" off, a full screen app on that screen does:
    /// the stack waits until you leave full screen.
    private var wanted = false
    /// Set while an empty stack shows its hint: on first launch, or when you
    /// show the stack with nothing on it. It goes away by itself.
    private var keepOpen = false {
        didSet { stack.showsHint = keepOpen }
    }
    /// Tells a hint's timer whether it is still the latest one.
    private var hintToken = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = NSHostingView(rootView: StackView(stack: stack))
        host.sizingOptions = []
        panel = StackPanel(content: host)
        panel.onPointerMove = { [weak self] in self?.pointerMoved() }
        stack.onLayout = { [weak self] in self?.updateMousePassThrough() }
        placePanel()

        // Ready to put the screenshot settings back before changing them.
        restoreSettingsOnTermination()
        if Inbox.isEnabled { Inbox.apply() }
        startWatcher()
        stack.sweepInbox()
        let sweep = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stack.sweepInbox() }
        }
        // No hurry: macOS may run it along with other work instead of waking up for it.
        sweep.tolerance = 10 * 60
        clipboardWatcher = ClipboardWatcher { [weak self] url in self?.addCapture(url) }
        if ClipboardWatcher.isEnabled { clipboardWatcher.start() }

        registerShortcuts()

        setUpStatusItem()

        Markup.shared.onSaved = { [weak self] url in self?.stack.reloadThumbnail(for: url) }
        Trim.shared.onSaved = { [weak self] url in self?.stack.reloadThumbnail(for: url) }
        stack.onFall = { [weak self] item in self?.fall(item) }

        stack.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.itemsChanged() }
            .store(in: &cancellables)
        // A drag can end without moving a card, with the pointer resting
        // wherever it let go.
        stack.$draggingID
            .receive(on: RunLoop.main)
            .sink { [weak self] id in if id == nil { self?.updateMousePassThrough() } }
            .store(in: &cancellables)
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateActiveTimer() }
            }
        }
        // Screenshots kept from last time come back, and stay.
        if stack.liveCount > 0 { showStack(on: nil) }

        // Entering or leaving full screen switches Space. Check again once the
        // switch animation has settled.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.refresh() }
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Stay on the same screen if it is still connected.
                self?.placePanel(on: self?.panel.screen)
            }
        }

        if !Inbox.wasOffered {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.offerInbox() }
        }

        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            showHint(for: 5)
        }
    }

    /// Opening the app again, from Finder or Spotlight, opens Settings: the
    /// usual way to reach a menu bar app's settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if Inbox.isEnabled { Inbox.restore() }
    }

    // MARK: Inbox mode

    private func startWatcher() {
        watcher?.stop()
        safetyWatcher?.stop()
        safetyWatcher = nil
        watcher = ScreenshotWatcher(
            onNew: { [weak self] url in self?.addCapture(url) },
            onChange: { [weak self] in self?.stack.prune() })
        watcher.start()
        if Inbox.isEnabled, watcher.folder.standardizedFileURL != ScreenshotWatcher.desktop.standardizedFileURL {
            let safety = ScreenshotWatcher(
                folder: ScreenshotWatcher.desktop,
                onNew: { [weak self] url in
                    // A screenshot you saved to the Desktop from the stack is
                    // kept, not a new capture.
                    guard let self, !self.stack.hasBeenOnStack(url) else { return }
                    log.notice("Screenshot landed on the Desktop despite inbox mode: \(url.lastPathComponent, privacy: .public)")
                    self.addCapture(url)
                },
                onChange: { [weak self] in self?.stack.prune() })
            safety.start()
            safetyWatcher = safety
        }
    }

    private func setInbox(_ on: Bool) {
        Inbox.isEnabled = on
        if on { Inbox.apply() } else { Inbox.restore() }
        startWatcher()
    }

    /// Asked once. Changing system settings is the user's call, never ours.
    private func offerInbox() {
        Inbox.wasOffered = true
        let alert = NSAlert()
        alert.messageText = L("Let Cornerstack handle your screenshots?")
        alert.informativeText = L(
            "Screenshots will land on the stack the instant you take them, without the floating thumbnail, and will not pile up on your Desktop. They stay in Cornerstack's folder for 30 days after they leave the stack; drag one to a folder to keep it for good. You can turn this off in Settings, and your screenshot settings come back when Cornerstack quits.")
        alert.addButton(withTitle: L("Turn on"))
        alert.addButton(withTitle: L("Not now"))
        if let icon = NSImage(named: "Cornerstack") ?? NSApp.applicationIconImage { alert.icon = icon }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { setInbox(true) }
    }

    /// Watching the clipboard is opt in, from Settings only.
    private func setClipboard(_ on: Bool) {
        ClipboardWatcher.isEnabled = on
        if on { clipboardWatcher.start() } else { clipboardWatcher.stop() }
        updateStatusIcon()
    }

    /// Quitting from the menu or logging out runs applicationWillTerminate.
    /// A plain kill does not, so settings are also restored on those signals.
    private func restoreSettingsOnTermination() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                if Inbox.isEnabled { Inbox.restore() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Showing and hiding

    /// An empty stack goes away, unless it is showing its hint.
    private func itemsChanged() {
        guard stack.liveCount == 0, !keepOpen else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.stack.liveCount == 0, !self.keepOpen else { return }
            self.wanted = false
            self.refresh()
        }
    }

    /// The stack shows on that screen and stays. Without a screen, it uses
    /// the one under the pointer.
    private func showStack(on screen: NSScreen?) {
        placePanel(on: screen)
        wanted = true
        hiddenByUser = false
        // Something to show now, so no hint, and the stack goes away again
        // once it is empty.
        keepOpen = false
        refresh()
    }

    /// An empty stack shows its hint for a moment, then goes away again.
    private func showHint(for seconds: TimeInterval) {
        keepOpen = true
        wanted = true
        refresh()
        hintToken += 1
        let token = hintToken
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.hintToken == token, self.keepOpen else { return }
            self.keepOpen = false
            if self.stack.liveCount == 0 {
                self.wanted = false
                self.refresh()
            }
        }
    }

    /// Puts the panel on that screen, or the one under the pointer, as wide
    /// as the cards need. The oldest cards leave if they no longer fit,
    /// unless `fitting` is false: while the width slider moves, they wait
    /// until it is let go.
    private func placePanel(on screen: NSScreen? = nil, fitting: Bool = true) {
        guard let screen = screen ?? StackPanel.screenUnderPointer() else { return }
        stack.cardWidth = CardWidth.custom ?? CardWidth.automatic(for: screen.visibleFrame)
        panel.placeOnScreen(screen, width: Layout.panelWidth(stack.cardWidth))
        stack.capacity = Layout.capacity(cardWidth: stack.cardWidth, height: panel.frame.height)
        if fitting { stack.trimToCapacity() }
        // The panel may have moved under a resting pointer.
        updateMousePassThrough()
    }

    private func openSettings() {
        settings.reload(soundsOn: stack.soundOn)
        settingsWindow.show(settings)
    }

    /// Takes the shortcuts set in Settings, the standard ones until then.
    /// While Settings takes a new one, it lets go of them all. Returns the
    /// actions whose shortcut macOS refused.
    @discardableResult
    private func registerShortcuts(paused: Bool = false) -> Set<ShortcutAction> {
        hotKeys = []
        guard !paused else { return [] }
        var refused = Set<ShortcutAction>()
        for action in ShortcutAction.allCases {
            guard let shortcut = action.shortcut else { continue }
            let run: () -> Void = { [weak self] in
                switch action {
                case .copyNewest: self?.copyNewest()
                case .toggleStack: self?.toggle()
                }
            }
            if let hotKey = HotKey(shortcut, action: run) {
                hotKeys.append(hotKey)
            } else {
                refused.insert(action)
            }
        }
        return refused
    }

    /// The newest card goes to the clipboard, like a click on it.
    private func copyNewest() {
        guard let newest = stack.items.last(where: { !$0.falling }) else {
            NSSound.beep()
            return
        }
        stack.copy(newest.id)
    }

    /// The card that left most recently comes back, flying in from where it
    /// was taken.
    private func putBack() {
        guard let url = stack.takeBackLastRemoved() else {
            NSSound.beep()
            return
        }
        addCapture(url)
    }

    // MARK: The capture flying to the stack

    /// A new screenshot lifts off from where it was taken and flies to its
    /// place on the stack. Without a known capture area it simply drops in.
    private func addCapture(_ url: URL) {
        let from = captureRect(of: url)
        // The flight starts out at the captured size, so it needs a sharper
        // image than the card, up to a limit: a full Retina screen would
        // otherwise be decoded at full resolution.
        let scale = from.flatMap(screen(containing:))?.backingScaleFactor ?? 2
        let flightPixels = from.map { Int(max($0.width, $0.height) * scale).clamped(to: 400...1500) }
        // A big screenshot takes a moment to decode, so that happens off the
        // main thread, once for both the card and its flight.
        decoder.async {
            let images = loadCapture(url, flightPixels: flightPixels)
            DispatchQueue.main.async { [weak self] in
                if let images { self?.land(url, images: images, from: from) }
            }
        }
    }

    private func land(_ url: URL, images: CaptureImages, from: CGRect?) {
        // Every capture shows the stack before it lands, on the screen it was
        // taken on. On a full stack the oldest card then falls in view as the
        // new one flies in.
        showStack(on: from.flatMap(screen(containing:)))
        guard let id = stack.add(url, thumb: images.card, flying: images.flight != nil) else {
            // Nothing was added after all, so an empty stack goes away again.
            itemsChanged()
            return
        }
        guard let from, let image = images.flight else { return }
        // Let the stack appear and lay out before measuring the landing spot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.fly(id, image: image, from: from)
        }
    }

    private func fly(_ id: UUID, image: CGImage, from: CGRect, retries: Int = 3) {
        // The landing spot comes from the laid out card, which can take a
        // frame or two to report itself.
        if cardFrame(for: id) == nil, retries > 0, isPresent, isShown {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                self?.fly(id, image: image, from: from, retries: retries - 1)
            }
            return
        }
        guard isPresent, isShown, CaptureFlight.flightsInProgress < 2, let screen = panel.screen,
              let to = cardFrame(for: id) else {
            stack.land(id)
            return
        }
        CaptureFlight.fly(image: image, from: from, to: to, on: screen) { [weak self] in
            self?.stack.land(id)
        }
    }

    /// The screen a capture was taken on.
    private func screen(containing rect: CGRect) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(CGPoint(x: rect.midX, y: rect.midY), $0.frame, false) }
    }

    /// A card that leaves falls over the whole screen, from where it sits.
    private func fall(_ item: Shot) {
        guard isPresent, isShown, !item.flying, let screen = panel.screen,
              let card = cardFrame(for: item.id),
              let image = item.thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        CaptureFlight.fall(image: image, card: card, on: screen)
    }

    /// Where a card sits, in screen coordinates, as the stack view reports
    /// it (top left origin, inside the panel).
    private func cardFrame(for id: UUID) -> CGRect? {
        guard let r = stack.hitRects[id], r.width > 0, r.height > 0 else { return nil }
        return CGRect(x: panel.frame.minX + r.minX,
                      y: panel.frame.maxY - r.maxY,
                      width: r.width, height: r.height)
    }

    /// Decides whether the stack is on screen: something to show, no full
    /// screen app in the way, and not hidden on purpose.
    private func refresh() {
        let blocked = panel.screen.map(FullScreen.blocksStack(on:))
            ?? StackPanel.screenUnderPointer().map(FullScreen.blocksStack(on:)) ?? false
        if wanted && !blocked {
            isPresent = true
            if !hiddenByUser { setShown(true) }
            // A Space switch (a full screen app coming up) can leave the
            // window behind it; bring it back in front.
            if isShown { panel.orderFrontRegardless() }
        } else {
            isPresent = false
            setShown(false)
        }
    }

    private func setShown(_ on: Bool) {
        guard on != isShown else { return }
        isShown = on
        stack.isShown = on
        // Hidden, the stack leaves no window behind: an invisible column
        // over the screen would still sit above other apps for anything that
        // checks what is on top, like screen automation.
        if on {
            panel.orderFrontRegardless()
        } else {
            panel.ignoresMouseEvents = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, !self.isShown else { return }
                self.panel.orderOut(nil)
            }
        }
        // The pointer only needs watching while there are cards to point at.
        if on { startMouseTracking() } else { stopMouseTracking() }
    }

    private func toggle() {
        if isShown {
            hiddenByUser = true
            keepOpen = false
            setShown(false)
            if stack.liveCount == 0 {
                wanted = false
                refresh()
            }
        } else {
            hiddenByUser = false
            placePanel()
            if stack.liveCount == 0 {
                showHint(for: 2.5)
            } else {
                wanted = true
                refresh()
            }
        }
    }

    // MARK: Following the pointer

    /// While the stack shows, it follows the pointer to know when to catch
    /// clicks. Moves over other apps reach a global monitor, which needs no
    /// permission for the mouse, moves sent to Cornerstack reach a local one,
    /// and the panel reports moves over itself. Nothing runs while the
    /// pointer rests.
    private func startMouseTracking() {
        guard mouseMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseUp]
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }
        mouseMonitors = [global, local].compactMap { $0 }
        updateActiveTimer()
        updateMousePassThrough()
    }

    private func stopMouseTracking() {
        mouseMonitors.forEach(NSEvent.removeMonitor)
        mouseMonitors = []
        updateActiveTimer()
        panel.ignoresMouseEvents = true
    }

    /// While Cornerstack itself is the active app, with Settings, Quick Look
    /// or Markup open, macOS may send it the pointer's moves without passing
    /// them on. Then it checks the pointer 30 times a second instead, until
    /// another app is active again.
    private func updateActiveTimer() {
        let wanted = isShown && NSApp.isActive
        if wanted && activeTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pointerMoved() }
            }
            RunLoop.main.add(timer, forMode: .common)
            activeTimer = timer
        } else if !wanted {
            activeTimer?.invalidate()
            activeTimer = nil
        }
    }

    private func pointerMoved() {
        // A drag or press that never reported its end freezes the stack: the
        // panel stops switching between catching clicks and letting them
        // through. With no button down, let go of it after a short grace period.
        if (GrabView.isDragging || stack.pressedID != nil) && NSEvent.pressedMouseButtons == 0 {
            let now = Date()
            let since = staleStateSince ?? now
            staleStateSince = since
            if now.timeIntervalSince(since) > 1.5 {
                GrabView.isDragging = false
                stack.draggingID = nil
                stack.pressedID = nil
                staleStateSince = nil
            }
        } else {
            staleStateSince = nil
        }
        updateMousePassThrough()
    }

    /// The panel is a tall column, so it only accepts the mouse while the
    /// cursor is over a card. Everywhere else, clicks go to whatever is
    /// underneath. Also called when something changes under a resting
    /// pointer: the cards move, a drag ends or the panel moves.
    private func updateMousePassThrough() {
        guard isShown, !GrabView.isDragging else { return }
        let local = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        let overCard = stack.hitRects.values.contains { $0.insetBy(dx: -4, dy: -4).contains(flipped) }
        if panel.ignoresMouseEvents == overCard {
            panel.ignoresMouseEvents = !overCard
        }
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()
        let menu = NSMenu()
        // Each item is enabled or not as menuNeedsUpdate decides, not by
        // AppKit's own checks, which would enable every one of them.
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
    }

    /// The icon fills in while copied images are added, so it shows at a
    /// glance that the clipboard is being watched.
    private func updateStatusIcon() {
        let on = ClipboardWatcher.isEnabled
        let description = on ? L("Cornerstack, watching the clipboard") : "Cornerstack"
        let image = NSImage(systemSymbolName: on ? "photo.stack.fill" : "photo.stack", accessibilityDescription: description)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = description
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let toggleItem = ClosureMenuItem(isShown ? L("Hide stack") : L("Show stack")) { [weak self] in
            self?.toggle()
        }
        ShortcutAction.toggleStack.shortcut?.show(in: toggleItem)
        menu.addItem(toggleItem)

        let copyItem = ClosureMenuItem(L("Copy newest")) { [weak self] in
            self?.copyNewest()
        }
        ShortcutAction.copyNewest.shortcut?.show(in: copyItem)
        copyItem.isEnabled = stack.liveCount > 0
        menu.addItem(copyItem)

        let putBackItem = ClosureMenuItem(L("Put back last card")) { [weak self] in
            self?.putBack()
        }
        putBackItem.isEnabled = stack.canPutBack
        menu.addItem(putBackItem)

        let clearItem = ClosureMenuItem(L("Clear stack")) { [weak self] in
            self?.stack.clear()
        }
        clearItem.isEnabled = stack.items.contains { !$0.falling && !$0.kept }
        menu.addItem(clearItem)

        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem(L("Open screenshots folder")) { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.watcher.folder)
        })
        menu.addItem(ClosureMenuItem(L("Settings…"), key: ",") { [weak self] in
            self?.openSettings()
        })

        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem(L("Quit Cornerstack"), key: "q") {
            NSApp.terminate(nil)
        })
    }

    /// Returns false, after saying why, when macOS refuses the change.
    private static func setOpenAtLogin(_ on: Bool) -> Bool {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Could not change the login setting")
            alert.informativeText = L("Move Cornerstack to the Applications folder and try again.")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return false
        }
    }

    // MARK: Quick Look

    /// Quick Look looks for its controller along the responder chain; with no
    /// window of ours, that is the app delegate, which hands it on.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLook.shared.take(panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLook.shared.release(panel)
    }
}
