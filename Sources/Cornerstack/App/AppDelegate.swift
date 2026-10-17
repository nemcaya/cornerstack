import AppKit
import Carbon
import Combine
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
    private var hotKey: HotKey?
    private var cancellables = Set<AnyCancellable>()
    private var mouseTimer: Timer?

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
    /// Whether the stack should be up, if nothing prevents it. With "Over
    /// full screen apps" off, a full screen app on that screen does: the
    /// stack waits until you leave full screen.
    private var wanted = false
    /// Set when you open the stack on purpose, so it stays up while empty
    /// and shows its hint.
    private var keepOpen = false {
        didSet { stack.showsHint = keepOpen }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = NSHostingView(rootView: StackView(stack: stack))
        host.sizingOptions = []
        panel = StackPanel(content: host)
        panel.placeOnScreen()

        // Ready to put the screenshot settings back before changing them.
        restoreSettingsOnTermination()
        if Inbox.isEnabled { Inbox.apply() }
        startWatcher()
        clipboardWatcher = ClipboardWatcher { [weak self] url in self?.addCapture(url) }
        if ClipboardWatcher.isEnabled { clipboardWatcher.start() }

        hotKey = HotKey(keyCode: kVK_ANSI_T, modifiers: controlKey | optionKey) { [weak self] in
            self?.toggle()
        }

        setUpStatusItem()

        Markup.shared.onSaved = { [weak self] url in self?.stack.reloadThumbnail(for: url) }
        Trim.shared.onSaved = { [weak self] url in self?.stack.reloadThumbnail(for: url) }
        stack.onFall = { [weak self] item in self?.fall(item) }

        stack.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.itemsChanged() }
            .store(in: &cancellables)
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
                self?.panel.placeOnScreen(self?.panel.screen)
            }
        }

        if !Inbox.wasOffered {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.offerInbox() }
        }

        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            keepOpen = true
            wanted = true
            refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self else { return }
                self.keepOpen = false
                if self.stack.liveCount == 0 {
                    self.wanted = false
                    self.refresh()
                }
            }
        }
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
            "Screenshots will land on the stack the instant you take them, without the floating thumbnail, and will not pile up on your Desktop. Drag one to a folder to keep it, or discard it with the cross. You can turn this off from the menu bar, and your settings come back when Cornerstack quits.")
        alert.addButton(withTitle: L("Turn on"))
        alert.addButton(withTitle: L("Not now"))
        if let icon = NSImage(named: "Cornerstack") ?? NSApp.applicationIconImage { alert.icon = icon }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { setInbox(true) }
    }

    /// Watching the clipboard is opt in, from the menu bar only.
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

    /// An empty stack goes away, unless it was opened on purpose.
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
        panel.placeOnScreen(screen)
        wanted = true
        hiddenByUser = false
        refresh()
    }

    // MARK: The capture flying to the stack

    /// A new screenshot lifts off from where it was taken and flies to its
    /// place on the stack. Without a known capture area it simply drops in.
    private func addCapture(_ url: URL) {
        let from = captureRect(of: url)
        let screen = from.flatMap { from in
            NSScreen.screens.first { NSMouseInRect(CGPoint(x: from.midX, y: from.midY), $0.frame, false) }
        }
        // Every capture shows the stack before it lands, on the screen it was
        // taken on. On a full stack the oldest card then falls in view as the
        // new one flies in.
        showStack(on: screen)
        guard let id = stack.add(url, flying: from != nil) else {
            // Nothing was added after all, so an empty stack goes away again.
            itemsChanged()
            return
        }
        guard let from else { return }
        // Let the stack appear and lay out before measuring the landing spot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.fly(id, from: from)
        }
    }

    private func fly(_ id: UUID, from: CGRect, retries: Int = 3) {
        // The landing spot comes from the laid out card, which can take a
        // frame or two to report itself.
        if cardFrame(for: id) == nil, retries > 0, isPresent, isShown {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                self?.fly(id, from: from, retries: retries - 1)
            }
            return
        }
        guard isPresent, isShown, CaptureFlight.flightsInProgress < 2, let screen = panel.screen,
              let to = cardFrame(for: id),
              let item = stack.items.first(where: { $0.id == id }) else {
            stack.land(id)
            return
        }
        // Sharp enough while it starts out at the captured size, which a
        // full Retina screen would otherwise take at full resolution.
        let pixels = Int(max(from.width, from.height) * screen.backingScaleFactor)
        guard let image = makeThumbnail(item.url, maxPixels: min(1500, max(400, pixels)))?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            stack.land(id)
            return
        }
        CaptureFlight.fly(image: image, from: from, to: to, on: screen) { [weak self] in
            self?.stack.land(id)
        }
    }

    /// A discarded card falls over the whole screen, from where it sits.
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
            keepOpen = true
            wanted = true
            panel.placeOnScreen()
            refresh()
        }
    }

    private func startMouseTracking() {
        guard mouseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func stopMouseTracking() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        panel.ignoresMouseEvents = true
    }

    private func tick() {
        let mouse = NSEvent.mouseLocation
        let now = Date()

        // A drag or press that never reported its end freezes the stack: the
        // panel stops switching between catching clicks and letting them
        // through. With no button down, let go of it after a short grace period.
        if (GrabView.isDragging || stack.pressedID != nil) && NSEvent.pressedMouseButtons == 0 {
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

        // All the stack needs to know is whether the pointer is over a card.
        guard isShown else { return }
        updateMousePassThrough(mouse)
    }

    /// The panel is a tall column, so it only accepts the mouse while the
    /// cursor is over a card. Everywhere else, clicks go to whatever is
    /// underneath.
    private func updateMousePassThrough(_ mouse: NSPoint) {
        guard !GrabView.isDragging else { return }
        let local = panel.convertPoint(fromScreen: mouse)
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
        toggleItem.keyEquivalent = "t"
        toggleItem.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(toggleItem)

        let clearItem = ClosureMenuItem(L("Clear stack")) { [weak self] in
            self?.stack.clear()
        }
        clearItem.isEnabled = stack.liveCount > 0
        menu.addItem(clearItem)

        let inbox = ClosureMenuItem(L("Handle screenshots")) { [weak self] in
            self?.setInbox(!Inbox.isEnabled)
        }
        inbox.state = Inbox.isEnabled ? .on : .off
        inbox.toolTip = L("Screenshots appear instantly and skip the Desktop")
        menu.addItem(inbox)

        let clipboard = ClosureMenuItem(L("Add copied images")) { [weak self] in
            self?.setClipboard(!ClipboardWatcher.isEnabled)
        }
        clipboard.state = ClipboardWatcher.isEnabled ? .on : .off
        clipboard.toolTip = L("Images you copy join the stack too")
        menu.addItem(clipboard)

        let fullScreen = ClosureMenuItem(L("Over full screen apps")) { [weak self] in
            FullScreen.showOverFullScreen.toggle()
            self?.refresh()
        }
        fullScreen.state = FullScreen.showOverFullScreen ? .on : .off
        menu.addItem(fullScreen)

        menu.addItem(ClosureMenuItem(L("Open screenshots folder")) { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.watcher.folder)
        })

        menu.addItem(.separator())

        let sound = ClosureMenuItem(L("Sounds")) { [weak self] in
            guard let self else { return }
            self.stack.soundOn.toggle()
        }
        sound.state = stack.soundOn ? .on : .off
        menu.addItem(sound)

        let login = ClosureMenuItem(L("Open at login")) {
            AppDelegate.toggleLaunchAtLogin()
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Quit Cornerstack"), key: "q") {
            NSApp.terminate(nil)
        })
    }

    private static func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Could not change the login setting")
            alert.informativeText = L("Move Cornerstack to the Applications folder and try again.")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
