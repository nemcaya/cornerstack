import AppKit
import SwiftUI

/// History: every capture of the last 30 days that was on the stack, newest
/// first, grouped by day. Drag one into any app, double click it to put it
/// back on the stack, or right click for the rest.
///
/// Captures in Cornerstack's own folder are all there, for as long as they
/// stay in the folder (`Inbox.keepDays`). Captures that went somewhere else,
/// like the Desktop, are remembered when they land on the stack, and listed
/// while their file is still where it was.
enum History {
    static var keepDays: Int { Inbox.keepDays }

    private static let key = "history"
    /// Enough for a busy month.
    private static let limit = 500

    /// Remembers a capture that landed on the stack, with when it did.
    /// `onlyIfNew` keeps the first time, for cards that come back on launch.
    static func record(_ url: URL, onlyIfNew: Bool = false) {
        var saved = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        if onlyIfNew && saved[url.path] != nil { return }
        saved[url.path] = Date().timeIntervalSince1970
        let cutoff = Date().addingTimeInterval(-Double(keepDays) * 24 * 60 * 60).timeIntervalSince1970
        saved = saved.filter { $0.value >= cutoff }
        if saved.count > limit {
            for (path, _) in saved.sorted(by: { $0.value < $1.value }).prefix(saved.count - limit) {
                saved[path] = nil
            }
        }
        UserDefaults.standard.set(saved, forKey: key)
    }

    /// Every capture to list, newest first: what is in Cornerstack's folder
    /// and what was remembered elsewhere, if its file is still there. Reads
    /// the disk, so call it off the main thread.
    static func entries() -> [HistoryEntry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .isRegularFileKey]
        let cutoff = Date().addingTimeInterval(-Double(keepDays) * 24 * 60 * 60)
        var found: [String: HistoryEntry] = [:]
        let inbox = (try? fm.contentsOfDirectory(at: Inbox.folder, includingPropertiesForKeys: keys,
                                                 options: [.skipsHiddenFiles])) ?? []
        for url in inbox where isCapture(url) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            found[url.standardizedFileURL.path] = HistoryEntry(url: url, date: values.creationDate ?? .distantPast,
                                                               modified: values.contentModificationDate)
        }
        let saved = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        for (path, time) in saved where found[path] == nil && fm.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            found[url.standardizedFileURL.path] = HistoryEntry(url: url,
                                                               date: values?.creationDate ?? Date(timeIntervalSince1970: time),
                                                               modified: values?.contentModificationDate)
        }
        return found.values
            .filter { $0.date >= cutoff || $0.url.deletingLastPathComponent().standardizedFileURL == Inbox.folder.standardizedFileURL }
            .sorted { $0.date > $1.date }
    }

    private static let extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp", "mov", "mp4"]

    private static func isCapture(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }
}

struct HistoryEntry: Identifiable, Hashable {
    let url: URL
    let date: Date
    /// When the file last changed, after Markup for example, so its
    /// thumbnail is made again.
    var modified: Date?
    var id: URL { url }
}

/// What the History window shows. AppDelegate supplies the actions.
@MainActor
final class HistoryModel: ObservableObject {
    struct Actions {
        var putBack: (URL) -> Void
        var isOnStack: (URL) -> Bool
        /// A file was moved to the Trash from History.
        var trashed: () -> Void
    }

    struct Day: Identifiable {
        let id: Date
        let title: String
        let entries: [HistoryEntry]
    }

    @Published private(set) var days: [Day] = []
    @Published private(set) var onStack: Set<URL> = []
    @Published private(set) var loaded = false
    /// A short note under one capture, like "Copied".
    @Published private(set) var note: (url: URL, text: String)?

    let actions: Actions
    private var reloading = false
    private var reloadAgain = false

    init(actions: Actions) {
        self.actions = actions
    }

    /// Reads the folder again, off the main thread.
    func reload() {
        guard !reloading else {
            reloadAgain = true
            return
        }
        reloading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let entries = History.entries()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.show(entries)
                    self.reloading = false
                    if self.reloadAgain {
                        self.reloadAgain = false
                        self.reload()
                    }
                }
            }
        }
    }

    /// The stack changed: which captures are on it now.
    func stackChanged() {
        let all = days.flatMap(\.entries).map(\.url)
        onStack = Set(all.filter(actions.isOnStack))
    }

    private func show(_ entries: [HistoryEntry]) {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.date) }
        days = grouped.keys.sorted(by: >).map { day in
            Day(id: day, title: Self.title(for: day), entries: grouped[day] ?? [])
        }
        loaded = true
        stackChanged()
    }

    /// Dates in the language the app speaks, like the rest of its text, in
    /// the Mac's region's style: English in Austria reads "Friday, 30
    /// October" and "20:00".
    static let locale: Locale = {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        guard let region = Locale.current.region?.identifier else { return Locale(identifier: language) }
        return Locale(identifier: language + "_" + region)
    }()

    private static func title(for day: Date) -> String {
        let calendar = Calendar.current
        let format = DateFormatter()
        format.locale = locale
        if calendar.isDateInToday(day) || calendar.isDateInYesterday(day) {
            // "Today", "Yesterday"
            format.dateStyle = .medium
            format.doesRelativeDateFormatting = true
        } else {
            format.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        }
        return format.string(from: day)
    }

    /// Times as the Mac shows them, 12 or 24 hour as set in System Settings.
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    // MARK: Actions

    /// The file was trashed in Finder or swept since the list was read: beep
    /// and read the folder again.
    private func exists(_ entry: HistoryEntry) -> Bool {
        guard FileManager.default.fileExists(atPath: entry.url.path) else {
            NSSound.beep()
            reload()
            return false
        }
        return true
    }

    /// The badge follows once the card has landed and History reloads.
    func putBack(_ entry: HistoryEntry) {
        guard !onStack.contains(entry.url), exists(entry) else { return }
        actions.putBack(entry.url)
    }

    func copy(_ entry: HistoryEntry) {
        guard exists(entry) else { return }
        Copying.copy(entry.url)
        flash(L("Copied"), on: entry)
    }

    func copyAtOneX(_ entry: HistoryEntry) {
        guard exists(entry) else { return }
        switch Copying.copyAtOneX(entry.url) {
        case .scaled: flash(L("Copied at 1x"), on: entry)
        case .alreadyOneX: flash(L("Copied, already 1x"), on: entry)
        case .failed: NSSound.beep()
        }
    }

    func copyText(_ entry: HistoryEntry) {
        guard exists(entry) else { return }
        Reader.shared.read(entry.url) { [weak self] reading in
            guard let text = reading.text else {
                self?.flash(L("No text found"), on: entry)
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self?.flash(L("Copied text"), on: entry)
        }
    }

    func quickLook(_ entry: HistoryEntry) {
        guard exists(entry) else { return }
        let all = days.flatMap(\.entries).map(\.url)
        QuickLook.shared.show(all, at: all.firstIndex(of: entry.url) ?? 0)
    }

    func showInFinder(_ entry: HistoryEntry) {
        guard exists(entry) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    func trash(_ entry: HistoryEntry) {
        do {
            try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
            actions.trashed()
            reload()
        } catch {
            log.error("Could not trash \(entry.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    private func flash(_ text: String, on entry: HistoryEntry) {
        note = (entry.url, text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.note?.url == entry.url && self?.note?.text == text { self?.note = nil }
        }
    }
}

struct HistoryView: View {
    @ObservedObject var model: HistoryModel

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 14)]

    var body: some View {
        Group {
            if model.loaded && model.days.isEmpty {
                Text(L("Screenshots from the last 30 days show up here once they have been on the stack."))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                        ForEach(model.days) { day in
                            Section {
                                ForEach(day.entries) { entry in
                                    HistoryCell(entry: entry, model: model)
                                }
                            } header: {
                                Text(day.title)
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 6)
                                    .background(.background)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
    }
}

private struct HistoryCell: View {
    let entry: HistoryEntry
    @ObservedObject var model: HistoryModel
    @State private var image: NSImage?

    private var onStack: Bool { model.onStack.contains(entry.url) }
    private var note: String? { model.note?.url == entry.url ? model.note?.text : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.1))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(4)
                }
                if isRecording(entry.url) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26)
                        .glassFrame(circle: true)
                }
                if let note {
                    Label(note, systemImage: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassFrame(capsule: true)
                        .transition(.opacity)
                }
            }
            .frame(height: 110)
            .overlay(alignment: .topTrailing) {
                if onStack {
                    Label(L("On the stack"), systemImage: "photo.stack.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .glassFrame(capsule: true)
                        .padding(6)
                }
            }
            Text(verbatim: HistoryModel.time(entry.date))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .animation(.easeOut(duration: 0.2), value: note)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.putBack(entry) }
        .onDrag { NSItemProvider(contentsOf: entry.url) ?? NSItemProvider() }
        .contextMenu {
            Button(L("Put back on stack")) { model.putBack(entry) }
                .disabled(onStack)
            Divider()
            Button(L("Copy")) { model.copy(entry) }
            if !isRecording(entry.url) {
                Button(L("Copy at 1x")) { model.copyAtOneX(entry) }
                Button(L("Copy Text")) { model.copyText(entry) }
            }
            Divider()
            Button(L("Quick Look")) { model.quickLook(entry) }
            Button(L("Show in Finder")) { model.showInFinder(entry) }
            Divider()
            Button(L("Move to Trash")) { model.trash(entry) }
        }
        .task(id: entry) {
            image = await HistoryThumbnails.shared.image(for: entry)
        }
    }
}

/// History's small images, made off the main thread and kept while there is
/// memory for them.
@MainActor
final class HistoryThumbnails {
    static let shared = HistoryThumbnails()
    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        // About half a megabyte each: a few screens of the grid.
        cache.countLimit = 120
        return cache
    }()

    func image(for entry: HistoryEntry) async -> NSImage? {
        // A file saved over, by Markup for example, gets a new thumbnail.
        let key = "\(entry.url.path)|\(entry.modified?.timeIntervalSince1970 ?? 0)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let url = entry.url
        let image = await Task.detached(priority: .utility) { makeThumbnail(url, maxPixels: 440) }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}

/// The History window, made once and shown again from the menu bar.
@MainActor
final class HistoryWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private weak var model: HistoryModel?

    /// On screen or in the Dock: either way it should stay up to date.
    var isOpen: Bool { window.map { $0.isVisible || $0.isMiniaturized } ?? false }

    func show(_ model: HistoryModel) {
        self.model = model
        model.reload()
        if window == nil {
            let host = NSHostingController(rootView: HistoryView(model: model))
            let window = NSWindow(contentViewController: host)
            window.title = L("Cornerstack History")
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.setContentSize(NSSize(width: 760, height: 560))
            window.isReleasedWhenClosed = false
            window.delegate = self
            // Where you left it last time, or the middle of the screen.
            if !window.setFrameUsingName("History") { window.center() }
            window.setFrameAutosaveName("History")
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Back from the Dock: files may have come and gone meanwhile.
    func windowDidDeminiaturize(_ notification: Notification) {
        model?.reload()
    }
}
