import AppKit
import Combine
import os
import UniformTypeIdentifiers

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
    /// A screen recording rather than a screenshot.
    var isRecording: Bool { Cornerstack.isRecording(url) }

    static func == (a: Shot, b: Shot) -> Bool {
        a.id == b.id && a.falling == b.falling && a.flying == b.flying && a.kept == b.kept
            && a.thumb === b.thumb
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

    /// Card frames in window coordinates, reported by the views. The panel
    /// uses them to only catch clicks over cards and let the rest through.
    var hitRects: [UUID: CGRect] = [:] {
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
        return item.id
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
        let entry = NSPasteboardItem()
        // A recording is copied as the file, which apps paste as the video.
        if !item.isRecording, let png = pngData(item.url) { entry.setData(png, forType: .png) }
        entry.setString(item.url.absoluteString, forType: .fileURL)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([entry])
        flash(L("Copied"), on: id)
    }

    /// The text in a screenshot, read on this Mac. See `TextRecognition`.
    func copyText(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        TextRecognition.text(in: item.url) { [weak self] text in
            guard let self else { return }
            guard let text else {
                self.flash(L("No text found"), symbol: "text.magnifyingglass", on: id)
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self.flash(L("Copied text"), on: id)
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

    /// A PNG file goes on the clipboard as it is; any other image is
    /// converted straight from the file, keeping its resolution and colours.
    private func pngData(_ url: URL) -> Data? {
        if url.pathExtension.lowercased() == "png" { return try? Data(contentsOf: url) }
        let data = NSMutableData()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
