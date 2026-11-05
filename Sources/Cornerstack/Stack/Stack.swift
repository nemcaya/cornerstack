import AppKit
import Combine
import os

let log = Logger(subsystem: "io.github.nemcaya.cornerstack", category: "stack")

/// One screenshot on the stack.
struct Shot: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var thumb: NSImage
    var falling = false
    /// Still flying in from where it was captured; the card waits hidden.
    var flying = false
    /// Kept on the stack: a drop into an app leaves it there, and new
    /// captures push other cards out first.
    var kept = false
    /// What a QR code or barcode in the screenshot says, once it was read;
    /// see `Reader`. The card then shows a button that opens or copies it.
    var code: String?
    /// A screen recording rather than a screenshot.
    var isRecording: Bool { Cornerstack.isRecording(url) }
    /// The code, when it is a web link.
    var link: URL? { code.flatMap(Reading.webLink) }

    static func == (a: Shot, b: Shot) -> Bool {
        a.id == b.id && a.falling == b.falling && a.flying == b.flying && a.kept == b.kept
            && a.code == b.code && a.thumb === b.thumb
    }
}

/// A short note over a card, like "Copied", that fades after a moment.
struct Badge: Equatable {
    let id: UUID
    let text: String
    let symbol: String
}

/// The stack itself: what is on it and what you can do with each item.
/// Files only move when you save or trash one, or when an old capture in
/// Cornerstack's folder is swept; otherwise the stack is just a view onto them.
@MainActor
final class Stack: ObservableObject {
    @Published private(set) var items: [Shot] = []
    @Published private(set) var badge: Badge?
    /// How wide the cards are on the current screen; see `CardWidth`.
    @Published var cardWidth: CGFloat = 200
    @Published var draggingID: UUID?
    @Published var pressedID: UUID?
    /// Whether the stack is on screen.
    @Published var isShown = false
    /// Whether an empty stack shows its hint: only when it was opened on
    /// purpose, not for the moment the last card leaves.
    @Published var showsHint = false
    /// Tucked away: the cards slid off the edge of the screen, and a small
    /// tab shows how many wait there. See `TuckAway`.
    @Published var isTucked = false
    /// Whether tucking away and coming back slide. A new capture brings the
    /// cards back at once, so it can fly straight to its place.
    @Published var tuckSlides = true

    /// Card frames in window coordinates, reported by the views. The panel
    /// uses them to only catch clicks over cards and let the rest through.
    var hitRects: [UUID: CGRect] = [:] {
        didSet { onLayout?() }
    }
    /// Where the tab of a tucked stack is, in the same coordinates.
    var tabRect: CGRect? {
        didSet { onLayout?() }
    }
    /// Called when the cards moved, so the panel can check again which
    /// clicks it catches without waiting for the pointer to move.
    var onLayout: (() -> Void)?

    var soundOn: Bool {
        get { !UserDefaults.standard.bool(forKey: "soundOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "soundOff") }
    }

    var liveCount: Int { items.filter { !$0.falling }.count }

    /// How many cards fit on the screen the stack is on. More than this and
    /// the oldest card leaves; see `Layout.capacity`.
    var capacity = Layout.maxItems

    private let storeKey = "shots"
    private let keptKey = "keptShots"
    /// Files of the cards that left most recently, newest last, for "Put back
    /// last card". Only kept while the app runs.
    private var removed: [URL] = []
    /// Names of every file that has been on the stack since launch, so a
    /// screenshot you saved to the Desktop is not picked up there again.
    private var seenNames = Set<String>()

    init() {
        restore()
    }

    // MARK: Adding and dropping

    /// `thumb` is the card's image, decoded off the main thread; see
    /// `loadCapture`.
    @discardableResult
    func add(_ url: URL, thumb: NSImage, flying: Bool = false) -> UUID? {
        guard !items.contains(where: { $0.url == url && !$0.falling }) else { return nil }
        var item = Shot(url: url, thumb: thumb)
        item.flying = flying
        items.append(item)
        seenNames.insert(url.lastPathComponent)
        removed.removeAll { $0 == url }
        trimToCapacity(sparing: item.id)
        save()
        play("Tink", volume: 0.35)
        read(item)
        History.record(url)
        return item.id
    }

    /// Reads the capture in the background, so its text is ready and a QR
    /// code shows its button. Recordings are left alone.
    private func read(_ item: Shot) {
        guard !item.isRecording else { return }
        let url = item.url
        Reader.shared.read(url) { [weak self] reading in
            guard let self, let i = self.items.firstIndex(where: { $0.url == url && !$0.falling }) else { return }
            let code = reading.code
            if self.items[i].code != code { self.items[i].code = code }
        }
    }

    /// Whether this file is on the stack now.
    func contains(_ url: URL) -> Bool {
        items.contains { $0.url == url && !$0.falling }
    }

    /// Whether a file with this name has been on the stack since launch.
    func hasBeenOnStack(_ url: URL) -> Bool {
        seenNames.contains(url.lastPathComponent)
    }

    /// The capture has reached the stack: the real card takes over.
    func land(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].flying = false
    }

    /// Called just before a photo starts falling, so the fall can be drawn
    /// over the whole screen.
    var onFall: ((Shot) -> Void)?

    func drop(_ id: UUID, quietly: Bool = false) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].falling else { return }
        remember(items[i].url)
        onFall?(items[i])
        items[i].falling = true
        hitRects[id] = nil
        save()
        if !quietly { play("Pop", volume: 0.25) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.items.removeAll { $0.id == id }
        }
    }

    /// "Clear stack": every card leaves, like with its corner cross, except
    /// the ones you keep. The files stay where they are.
    func clear() {
        let live = items.filter { !$0.falling && !$0.kept }
        for (n, item) in live.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(n)) { [weak self] in
                self?.drop(item.id, quietly: n > 0)
            }
        }
    }

    /// A full stack lets cards go until it fits: the oldest one you don't
    /// keep first, the oldest kept one only when every card is kept. Their
    /// files stay where they are.
    func trimToCapacity(sparing spared: UUID? = nil) {
        while liveCount > capacity {
            let candidates = items.filter { !$0.falling && $0.id != spared }
            guard let leaving = candidates.first(where: { !$0.kept }) ?? candidates.first else { return }
            letGo(leaving.id)
        }
    }

    /// Photos whose file was deleted or moved away fall off by themselves.
    func prune() {
        for item in items where !item.falling && !FileManager.default.fileExists(atPath: item.url.path) {
            drop(item.id, quietly: true)
        }
    }

    // MARK: Actions on one photo

    func copy(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        Copying.copy(item.url)
        flash(L("Copied"), on: id)
    }

    /// Half the size of a Retina screenshot, as it looked on screen; see
    /// `Copying.copyAtOneX`.
    func copyAtOneX(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        guard !item.isRecording else {
            NSSound.beep()
            return
        }
        switch Copying.copyAtOneX(item.url) {
        case .scaled: flash(L("Copied at 1x"), on: id)
        case .alreadyOneX: flash(L("Copied, already 1x"), on: id)
        case .failed: NSSound.beep()
        }
    }

    /// The text in a screenshot, read on this Mac, with what a QR code in it
    /// says at the end. Usually read already, when the card landed; see `Reader`.
    func copyText(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), !item.isRecording else { return }
        Reader.shared.read(item.url) { [weak self] reading in
            guard let self else { return }
            guard let text = reading.text else {
                self.flash(L("No text found"), symbol: "text.magnifyingglass", on: id)
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self.flash(L("Copied text"), on: id)
        }
    }

    /// The button for a card's QR code or barcode: a web link opens in the
    /// browser, anything else a code says is copied.
    func useCode(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        guard let code = item.code else {
            flash(L("No code found"), symbol: "qrcode", on: id)
            return
        }
        if let link = item.link {
            NSWorkspace.shared.open(link)
            flash(L("Opened link"), symbol: "arrow.up.right", on: id)
        } else {
            copyCode(id, code: code)
        }
    }

    func copyCode(_ id: UUID) {
        guard let code = items.first(where: { $0.id == id })?.code else { return }
        copyCode(id, code: code)
    }

    private func copyCode(_ id: UUID, code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        flash(items.first(where: { $0.id == id })?.link != nil ? L("Copied link") : L("Copied code"), on: id)
    }

    /// A copy of the screenshot with its keys, tokens, passwords, email
    /// addresses, card numbers and IBANs painted over lands on the stack as
    /// the newest card. The original stays as it is. See `Secrets`.
    func hideSecrets(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), !item.isRecording else { return }
        let url = item.url
        Reader.shared.read(url) { [weak self] reading in
            guard let self else { return }
            let boxes = Secrets.find(in: reading)
            guard !boxes.isEmpty else {
                self.flash(L("No secrets found"), symbol: "checkmark.shield", on: id)
                return
            }
            try? FileManager.default.createDirectory(at: Inbox.folder, withIntermediateDirectories: true)
            let base = (url.lastPathComponent as NSString).deletingPathExtension
            let target = self.uniqueURL(in: Inbox.folder, for: base + " " + L("(secrets hidden)") + ".png")
            DispatchQueue.global(qos: .userInitiated).async {
                let thumb = Secrets.paint(boxes, over: url, to: target) ? makeThumbnail(target) : nil
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        // In inbox mode the folder watcher may have put the
                        // copy on the stack first; that is fine too.
                        let existing = self.items.first { $0.url == target && !$0.falling }?.id
                        guard let thumb, let newID = existing ?? self.add(target, thumb: thumb) else {
                            log.error("Could not hide the secrets in \(url.lastPathComponent, privacy: .public)")
                            NSSound.beep()
                            return
                        }
                        self.flash(L("Secrets hidden"), symbol: "eye.slash", on: newID)
                    }
                }
            }
        }
    }

    /// The file's path, quoted for a shell, for tools in a terminal.
    func copyPath(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let quoted = "'" + item.url.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(quoted, forType: .string)
        flash(L("Copied path"), on: id)
    }

    /// Quick Look on this card, with the rest of the stack a key press away.
    func quickLook(_ id: UUID) {
        let live = items.filter { !$0.falling }
        guard let index = live.firstIndex(where: { $0.id == id }) else { return }
        QuickLook.shared.show(live.map(\.url), at: index)
    }

    /// A drop into an app: the card leaves, unless you keep it.
    func dropUnlessKept(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), !item.kept else { return }
        drop(id)
    }

    func toggleKeep(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].kept.toggle()
        save()
    }

    func open(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.open(item.url)
    }

    /// Moves the file to the Trash and takes the photo off the stack. When a
    /// drag ends on the Dock's Trash, macOS only reports it: deleting the file
    /// is the source app's job, as Finder does.
    @discardableResult
    func trash(_ id: UUID, quietly: Bool = false) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            log.notice("Trashed \(item.url.lastPathComponent, privacy: .public)")
            if soundOn && !quietly { Stack.trashSound?.play() }
            drop(id, quietly: true)
            return true
        } catch {
            log.error("Could not trash \(item.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            if !quietly { NSSound.beep() }
            return false
        }
    }

    private static let trashSound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag to trash.aif",
        byReference: true)

    /// Whether the file lives in Cornerstack's own folder rather than
    /// somewhere you chose, like the Desktop.
    func isInInbox(_ id: UUID) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        return item.url.standardizedFileURL.path.hasPrefix(Inbox.folder.standardizedFileURL.path + "/")
    }

    /// The oldest photo leaving a full stack. Its file stays where it is.
    private func letGo(_ id: UUID) {
        drop(id, quietly: true)
    }

    // MARK: Putting back

    /// Whether a card that left can come back: its file is still there and
    /// it is not on the stack already.
    var canPutBack: Bool { removed.contains(where: canComeBack) }

    /// The file of the card that left most recently and can come back.
    func takeBackLastRemoved() -> URL? {
        while let url = removed.popLast() {
            if canComeBack(url) { return url }
        }
        return nil
    }

    private func canComeBack(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            && !items.contains(where: { $0.url == url && !$0.falling })
    }

    private func remember(_ url: URL) {
        removed.removeAll { $0 == url }
        removed.append(url)
        if removed.count > Layout.maxItems { removed.removeFirst() }
    }

    /// Inbox mode: keep a screenshot by moving it to the Desktop.
    func saveToDesktop(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let target = uniqueURL(in: ScreenshotWatcher.desktop, for: item.url.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: item.url, to: target)
            seenNames.insert(target.lastPathComponent)
            drop(id, quietly: true)
        } catch {
            log.error("Could not save to Desktop: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    private func uniqueURL(in folder: URL, for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    /// Long press: open the photo in the system Markup editor. Markup does
    /// not edit video, so a recording opens in the trimming editor instead.
    func markup(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if item.isRecording {
            Trim.shared.edit(item.url, size: item.thumb.size)
        } else {
            Markup.shared.edit(item.url)
        }
    }

    /// After editing, the photo on the stack shows the new version.
    func reloadThumbnail(for url: URL) {
        guard let i = items.firstIndex(where: { $0.url == url && !$0.falling }),
              let thumb = makeThumbnail(url) else { return }
        items[i].thumb = thumb
        // What it says may have changed too.
        Reader.shared.forget(url)
        items[i].code = nil
        read(items[i])
    }

    func showInFinder(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: Cornerstack's folder

    /// Captures in Cornerstack's own folder stay there after they leave the
    /// stack, so you can still find them. After `Inbox.keepDays` they move to
    /// the Trash, or the folder would grow forever. Anything you want to keep
    /// for good, drag out.
    func sweepInbox() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(Inbox.keepDays) * 24 * 60 * 60)
        let onStack = Set(items.map(\.url.standardizedFileURL))
        let keys: Set<URLResourceKey> = [.creationDateKey, .isRegularFileKey]
        let files = (try? fm.contentsOfDirectory(
            at: Inbox.folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        var swept = 0
        for file in files where !onStack.contains(file.standardizedFileURL) {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let created = values.creationDate, created < cutoff else { continue }
            if (try? fm.trashItem(at: file, resultingItemURL: nil)) != nil { swept += 1 }
        }
        if swept > 0 { log.notice("Moved \(swept) old captures to the Trash") }
    }

    // MARK: Persistence

    private func save() {
        let live = items.filter { !$0.falling }
        UserDefaults.standard.set(live.map(\.url.path), forKey: storeKey)
        UserDefaults.standard.set(live.filter(\.kept).map(\.url.path), forKey: keptKey)
    }

    /// Everything comes back as it was, without the sound and the save that
    /// `add` does.
    private func restore() {
        let paths = UserDefaults.standard.stringArray(forKey: storeKey) ?? []
        let kept = Set(UserDefaults.standard.stringArray(forKey: keptKey) ?? [])
        for path in paths where FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            guard !items.contains(where: { $0.url == url }), let thumb = makeThumbnail(url) else { continue }
            var item = Shot(url: url, thumb: thumb)
            item.kept = kept.contains(path)
            items.append(item)
            seenNames.insert(url.lastPathComponent)
            read(item)
            History.record(url, onlyIfNew: true)
        }
    }

    // MARK: Helpers

    private func flash(_ text: String, symbol: String = "checkmark", on id: UUID) {
        let note = Badge(id: id, text: text, symbol: symbol)
        badge = note
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.badge == note { self?.badge = nil }
        }
    }

    private func play(_ name: String, volume: Float) {
        guard soundOn, let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }
}
