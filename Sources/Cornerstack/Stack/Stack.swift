import AppKit
import Combine
import os

let log = Logger(subsystem: "io.github.slover69.cornerstack", category: "stack")

/// One screenshot on the stack.
struct Shot: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var thumb: NSImage
    var falling = false
    /// Still flying in from where it was captured; the card waits hidden.
    var flying = false
    /// A screen recording rather than a screenshot.
    var isRecording: Bool { Cornerstack.isRecording(url) }

    static func == (a: Shot, b: Shot) -> Bool {
        a.id == b.id && a.falling == b.falling && a.flying == b.flying && a.thumb === b.thumb
    }
}

/// The stack itself: what is on it and what you can do with each item.
/// Files only move when you save or trash one, or when an old capture in
/// Cornerstack's folder is swept; otherwise the stack is just a view onto them.
@MainActor
final class Stack: ObservableObject {
    @Published private(set) var items: [Shot] = []
    @Published var copiedID: UUID?
    @Published var draggingID: UUID?
    @Published var pressedID: UUID?
    /// Whether the stack is on screen.
    @Published var isShown = false
    /// Whether an empty stack shows its hint: only when it was opened on
    /// purpose, not for the moment the last card leaves.
    @Published var showsHint = false

    /// Card frames in window coordinates, reported by the views. The panel
    /// uses them to only catch clicks over photos and let the rest through.
    var hitRects: [UUID: CGRect] = [:]

    var soundOn: Bool {
        get { !UserDefaults.standard.bool(forKey: "soundOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "soundOff") }
    }

    var liveCount: Int { items.filter { !$0.falling }.count }

    private let storeKey = "shots"
    /// Names of every file that has been on the stack since launch, so a
    /// screenshot you saved to the Desktop is not picked up there again.
    private var seenNames = Set<String>()

    init() {
        restore()
    }

    // MARK: Adding and dropping

    @discardableResult
    func add(_ url: URL, flying: Bool = false) -> UUID? {
        guard !items.contains(where: { $0.url == url && !$0.falling }),
              let thumb = makeThumbnail(url) else { return nil }
        var item = Shot(url: url, thumb: thumb)
        item.flying = flying
        items.append(item)
        seenNames.insert(url.lastPathComponent)
        // A full stack lets the oldest card go. Its file stays where it is.
        if liveCount > Layout.maxItems, let oldest = items.first(where: { !$0.falling }) {
            letGo(oldest.id)
        }
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
        onFall?(items[i])
        items[i].falling = true
        hitRects[id] = nil
        save()
        if !quietly { play("Pop", volume: 0.25) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.items.removeAll { $0.id == id }
        }
    }

    /// "Clear stack": every card leaves, like with its corner cross. The
    /// files stay where they are.
    func clear() {
        let live = items.filter { !$0.falling }
        for (n, item) in live.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(n)) { [weak self] in
                self?.drop(item.id, quietly: n > 0)
            }
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

        copiedID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copiedID == id { self?.copiedID = nil }
        }
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
        let paths = items.filter { !$0.falling }.map(\.url.path)
        UserDefaults.standard.set(paths, forKey: storeKey)
    }

    /// Everything comes back as it was, without the sound and the save that
    /// `add` does.
    private func restore() {
        let paths = UserDefaults.standard.stringArray(forKey: storeKey) ?? []
        for path in paths where FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            guard !items.contains(where: { $0.url == url }), let thumb = makeThumbnail(url) else { continue }
            items.append(Shot(url: url, thumb: thumb))
            seenNames.insert(url.lastPathComponent)
        }
    }

    // MARK: Helpers

    private func play(_ name: String, volume: Float) {
        guard soundOn, let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }

    private func pngData(_ url: URL) -> Data? {
        if url.pathExtension.lowercased() == "png" { return try? Data(contentsOf: url) }
        guard let tiff = NSImage(contentsOf: url)?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
