import Foundation

/// Inbox mode: Cornerstack takes over where screenshots go.
///
/// It changes the macOS screenshot settings in the Options menu of
/// Cmd+Shift+5: the floating thumbnail is turned off, so the file is written
/// at once instead of five seconds later, and captures are saved as files in
/// Cornerstack's own folder, so the Desktop only gets what you keep. Saving to
/// the clipboard or Preview would leave nothing to pick up, and a click on the
/// stack copies anyway.
/// Screen recordings go there too, and land on the stack like screenshots.
///
/// The previous values are saved first and put back when the mode is turned
/// off or the app quits, so macOS is never left pointing at a folder nobody
/// is watching. A setting you change in the meantime, in Cmd+Shift+5 for
/// example, is yours and is left as it is.
enum Inbox {
    private static let domain = "com.apple.screencapture" as CFString

    /// One screenshot setting that inbox mode changes: its key, the name its
    /// previous value is saved under, and the value inbox mode gives it.
    private struct Setting {
        let key: String
        let savedAs: String
        let value: NSObject
    }

    /// macOS 26 and earlier read "location" and "target". macOS 27 reads
    /// "location-screenshot" and "target-screenshot", and keeps screen
    /// recordings apart in their own pair; earlier versions send recordings
    /// wherever "location" points. All of them are written.
    private static var settings: [Setting] {
        let path = folder.path as NSString
        let file = "file" as NSString
        return [
            Setting(key: "location", savedAs: "location", value: path),
            Setting(key: "location-screenshot", savedAs: "locationScreenshot", value: path),
            Setting(key: "location-screenrecording", savedAs: "locationRecording", value: path),
            // A file, rather than the clipboard, Preview and so on.
            Setting(key: "target", savedAs: "target", value: file),
            Setting(key: "target-screenshot", savedAs: "targetScreenshot", value: file),
            Setting(key: "target-screenrecording", savedAs: "targetRecording", value: file),
            Setting(key: "show-thumbnail", savedAs: "thumbnail", value: false as NSNumber),
        ]
    }

    private static let enabledKey = "inboxEnabled"
    private static let offeredKey = "inboxOffered"
    private static let savedKey = "inboxSavedSettings"

    /// How long a capture stays in the folder once it has left the stack,
    /// before it moves to the Trash.
    static let keepDays = 30

    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Cornerstack/Screenshots", isDirectory: true)
    }()

    /// The user's choice, kept across launches.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Whether we already asked, so the offer appears only once.
    static var wasOffered: Bool {
        get { UserDefaults.standard.bool(forKey: offeredKey) }
        set { UserDefaults.standard.set(newValue, forKey: offeredKey) }
    }

    static func apply() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The user's settings are saved once. If they are still saved, the
        // app ended without putting them back, and what macOS has now are
        // our own values.
        if UserDefaults.standard.dictionary(forKey: savedKey) == nil {
            UserDefaults.standard.set(currentSettings(), forKey: savedKey)
        }
        for setting in settings { set(setting.key, setting.value) }
    }

    /// Puts back every setting that still has the value inbox mode gave it.
    static func restore() {
        guard let saved = UserDefaults.standard.dictionary(forKey: savedKey) else { return }
        for setting in settings where value(setting.key)?.isEqual(setting.value) == true {
            set(setting.key, saved[setting.savedAs])
        }
        UserDefaults.standard.removeObject(forKey: savedKey)
    }

    /// The settings as they are now, by the names they are saved under. A
    /// missing key is left out and comes back as the macOS default.
    private static func currentSettings() -> [String: Any] {
        // Screenshots going to a folder inside ~/Library belong to another
        // app that took them over, like the app this one grew out of. That
        // app is not around to empty its folder later, so the macOS defaults
        // are what comes back instead of its settings.
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path + "/"
        let location = (value("location-screenshot") ?? value("location")) as? String
        if let location, (location as NSString).expandingTildeInPath.hasPrefix(library) { return [:] }

        var saved: [String: Any] = [:]
        for setting in settings { saved[setting.savedAs] = value(setting.key) }
        return saved
    }

    private static func value(_ key: String) -> NSObject? {
        CFPreferencesCopyAppValue(key as CFString, domain) as? NSObject
    }

    /// Writes through cfprefsd, so the screenshot service sees it at once.
    /// A nil value removes the key and returns it to the macOS default.
    private static func set(_ key: String, _ value: Any?) {
        CFPreferencesSetAppValue(key as CFString, value as CFPropertyList?, domain)
        CFPreferencesAppSynchronize(domain)
    }
}
