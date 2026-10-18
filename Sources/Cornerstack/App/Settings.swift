import AppKit
import Carbon
import ServiceManagement
import SwiftUI

/// What the Settings window shows and changes. AppDelegate supplies the
/// actions, so the window itself never touches the screenshot settings, the
/// watchers or the panel.
@MainActor
final class SettingsModel: ObservableObject {
    struct Actions {
        /// Re-reads the card width and lays the stack out again. `fitting` is
        /// false while the slider moves: cards that no longer fit wait until
        /// it is let go.
        var applyCardWidth: (_ fitting: Bool) -> Void
        /// The width Automatic picks for the screen the stack is on.
        var automaticWidth: () -> CGFloat
        var setInbox: (Bool) -> Void
        var setClipboard: (Bool) -> Void
        var setOverFullScreen: (Bool) -> Void
        var setSounds: (Bool) -> Void
        /// Returns false when macOS refused the change.
        var setOpenAtLogin: (Bool) -> Bool
        /// Takes the shortcuts again, or lets go of them while a new one is
        /// typed. Returns the actions whose shortcut macOS refused.
        var registerShortcuts: (_ paused: Bool) -> Set<ShortcutAction>
    }

    @Published private(set) var automaticSize = true
    @Published private(set) var width: CGFloat = 200
    @Published private(set) var handleScreenshots = false
    @Published private(set) var addCopiedImages = false
    @Published private(set) var overFullScreen = true
    @Published private(set) var sounds = true
    @Published private(set) var openAtLogin = false
    @Published private(set) var shortcuts: [ShortcutAction: Shortcut] = [:]
    /// The shortcut being typed, and what to tell you about the last try.
    @Published private(set) var recording: ShortcutAction?
    @Published private(set) var hint: String?

    private let actions: Actions
    private var keyMonitor: Any?

    init(actions: Actions) {
        self.actions = actions
    }

    /// Reads every value fresh, each time the window opens.
    func reload(soundsOn: Bool) {
        automaticSize = CardWidth.custom == nil
        width = CardWidth.custom ?? actions.automaticWidth()
        handleScreenshots = Inbox.isEnabled
        addCopiedImages = ClipboardWatcher.isEnabled
        overFullScreen = FullScreen.showOverFullScreen
        sounds = soundsOn
        openAtLogin = SMAppService.mainApp.status == .enabled
        loadShortcuts()
    }

    func setAutomaticSize(_ on: Bool) {
        automaticSize = on
        if on {
            CardWidth.custom = nil
            width = actions.automaticWidth()
        } else {
            CardWidth.custom = width
        }
        actions.applyCardWidth(true)
    }

    /// A preset or the slider: the size becomes custom.
    func setWidth(_ value: CGFloat, sliding: Bool = false) {
        width = value.rounded().clamped(to: CardWidth.range)
        automaticSize = false
        CardWidth.custom = width
        actions.applyCardWidth(!sliding)
    }

    /// The slider was let go.
    func finishSliding() {
        actions.applyCardWidth(true)
    }

    func setHandleScreenshots(_ on: Bool) {
        handleScreenshots = on
        actions.setInbox(on)
    }

    func setAddCopiedImages(_ on: Bool) {
        addCopiedImages = on
        actions.setClipboard(on)
    }

    func setOverFullScreen(_ on: Bool) {
        overFullScreen = on
        actions.setOverFullScreen(on)
    }

    func setSounds(_ on: Bool) {
        sounds = on
        actions.setSounds(on)
    }

    func setOpenAtLogin(_ on: Bool) {
        if actions.setOpenAtLogin(on) { openAtLogin = on }
    }

    // MARK: Shortcuts

    /// The next keys pressed become the shortcut for that action. Escape
    /// keeps the old one and Delete turns it off.
    func record(_ action: ShortcutAction) {
        stopRecording()
        recording = action
        // Let go of the shortcuts, or they would catch the keys first.
        _ = actions.registerShortcuts(true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.typed(event) }
            return nil
        }
    }

    /// Stops taking a new shortcut, if one is being typed, and takes the
    /// shortcuts again.
    func stopRecording() {
        guard recording != nil else { return }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        recording = nil
        hint = nil
        _ = actions.registerShortcuts(false)
        loadShortcuts()
    }

    private func typed(_ event: NSEvent) {
        guard let action = recording, !event.isARepeat else { return }
        let bare = event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift])
        let keyCode = Int(event.keyCode)
        if bare && keyCode == kVK_Escape { return stopRecording() }
        if bare && (keyCode == kVK_Delete || keyCode == kVK_ForwardDelete) {
            action.shortcut = nil
            return stopRecording()
        }
        guard let shortcut = Shortcut(event: event) else {
            hint = L("Add ⌥ or ⌃")
            return
        }
        guard !ShortcutAction.allCases.contains(where: { $0 != action && $0.shortcut == shortcut }) else {
            hint = L("Already in use")
            return
        }
        let previous = action.shortcut
        action.shortcut = shortcut
        if actions.registerShortcuts(false).contains(action) {
            // macOS keeps these keys for itself: try others.
            action.shortcut = previous
            _ = actions.registerShortcuts(true)
            hint = L("Not available")
            return
        }
        stopRecording()
    }

    private func loadShortcuts() {
        shortcuts = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.compactMap { action in
            action.shortcut.map { (action, $0) }
        })
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section(L("Cards")) {
                Picker(L("Size"), selection: Binding(get: { model.automaticSize },
                                                     set: { model.setAutomaticSize($0) })) {
                    Text(L("Automatic")).tag(true)
                    Text(L("Custom")).tag(false)
                }
                .pickerStyle(.segmented)

                Picker(L("Preset"), selection: Binding(get: { model.width },
                                                       set: { model.setWidth($0) })) {
                    ForEach(CardWidth.presets, id: \.width) { preset in
                        Text(preset.name).tag(preset.width)
                    }
                }
                .pickerStyle(.segmented)

                LabeledContent(L("Width")) {
                    HStack {
                        Slider(value: Binding(get: { model.width }, set: { model.setWidth($0, sliding: true) }),
                               in: CardWidth.range,
                               onEditingChanged: { editing in if !editing { model.finishSliding() } })
                        Text(verbatim: "\(Int(model.width)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }

            Section {
                Toggle(L("Handle screenshots"), isOn: Binding(get: { model.handleScreenshots },
                                                             set: { model.setHandleScreenshots($0) }))
                Toggle(L("Add copied images"), isOn: Binding(get: { model.addCopiedImages },
                                                            set: { model.setAddCopiedImages($0) }))
                Toggle(L("Show over full screen apps"), isOn: Binding(get: { model.overFullScreen },
                                                                     set: { model.setOverFullScreen($0) }))
            } header: {
                Text(L("Screenshots"))
            } footer: {
                Text(L("Handled screenshots skip the Desktop and stay in Cornerstack's folder for 30 days after they leave the stack."))
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(ShortcutAction.allCases, id: \.self) { action in
                    LabeledContent(action.title) {
                        Button {
                            if model.recording == action { model.stopRecording() } else { model.record(action) }
                        } label: {
                            Text(model.recording == action ? model.hint ?? L("Press keys…")
                                 : model.shortcuts[action]?.display ?? L("None"))
                                .frame(minWidth: 96)
                        }
                    }
                }
            } header: {
                Text(L("Shortcuts"))
            } footer: {
                Text(L("Click a shortcut, then press the new keys. Escape keeps it, Delete turns it off."))
                    .foregroundStyle(.secondary)
            }

            Section(L("General")) {
                Toggle(L("Sounds"), isOn: Binding(get: { model.sounds }, set: { model.setSounds($0) }))
                Toggle(L("Open at login"), isOn: Binding(get: { model.openAtLogin },
                                                        set: { model.setOpenAtLogin($0) }))
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The Settings window, made once and shown again from the menu bar.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private weak var model: SettingsModel?

    func show(_ model: SettingsModel) {
        self.model = model
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(model: model))
            host.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: host)
            window.title = L("Cornerstack Settings")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Typing a new shortcut ends when the window closes or you switch away.
    func windowDidResignKey(_ notification: Notification) {
        model?.stopRecording()
    }
}
