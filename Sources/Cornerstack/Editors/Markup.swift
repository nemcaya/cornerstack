import AppKit
import UniformTypeIdentifiers

/// Opens a screenshot in the system Markup editor, the window macOS shows
/// when you click the thumbnail of a screenshot you just took. It is a
/// system extension, reached through the sharing service it registers.
@MainActor
final class Markup: NSObject, NSSharingServiceDelegate {
    static let shared = Markup()

    /// Called with the file once the edited image has been written back.
    var onSaved: (URL) -> Void = { _ in }

    /// The file each open Markup window edits. Several can be open at once,
    /// and each one's result belongs to its own file.
    private var editing: [ObjectIdentifier: URL] = [:]
    private static let serviceName = NSSharingService.Name("com.apple.MarkupUI.Markup")

    func edit(_ url: URL) {
        guard let service = NSSharingService(named: Markup.serviceName),
              service.canPerform(withItems: [url]) else {
            // Without the extension, Preview is the closest thing.
            NSWorkspace.shared.open(url)
            return
        }
        editing[ObjectIdentifier(service)] = url
        service.delegate = self
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: [url])
    }

    // MARK: NSSharingServiceDelegate

    /// Done was pressed. The extension hands back the edited image and the
    /// host app is the one that writes it over the original file.
    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        let key = ObjectIdentifier(sharingService)
        MainActor.assumeIsolated {
            guard let target = self.editing.removeValue(forKey: key) else { return }
            self.save(items, to: target)
        }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService,
                                    didFailToShareItems items: [Any], error: Error) {
        let key = ObjectIdentifier(sharingService)
        MainActor.assumeIsolated { _ = self.editing.removeValue(forKey: key) }
        log.notice("Markup ended without saving: \(error.localizedDescription, privacy: .public)")
    }

    // MARK: Writing back

    private func save(_ items: [Any], to target: URL) {
        guard let item = items.first else { return }
        log.notice("Markup returned \(String(describing: type(of: item)), privacy: .public)")

        switch item {
        case let url as URL:
            write(from: url, to: target)
        case let image as NSImage:
            write(data: encode(image, like: target), to: target)
        case let provider as NSItemProvider:
            load(provider, into: target)
        default:
            log.error("Markup returned an unexpected item")
        }
    }

    private func load(_ provider: NSItemProvider, into target: URL) {
        let types = provider.registeredTypeIdentifiers
        log.notice("Markup provider types: \(types.joined(separator: ", "), privacy: .public)")

        if types.contains(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                // The file may be a temporary one that is gone once this
                // returns, so it is read here.
                let edited = url.standardizedFileURL == target.standardizedFileURL
                let data = edited ? nil : try? Data(contentsOf: url)
                DispatchQueue.main.async {
                    if edited { self.onSaved(target) } else { self.write(data: data, to: target) }
                }
            }
            return
        }
        // Prefer the original format, then any image format.
        let original = UTType(filenameExtension: target.pathExtension)?.identifier
        let imageType = types.first { $0 == original }
            ?? types.first { UTType($0)?.conforms(to: .image) == true }
        guard let imageType else { return }
        provider.loadDataRepresentation(forTypeIdentifier: imageType) { data, _ in
            DispatchQueue.main.async { self.write(data: data, to: target) }
        }
    }

    private func write(from source: URL, to target: URL) {
        if source.standardizedFileURL == target.standardizedFileURL {
            onSaved(target)
        } else {
            write(data: try? Data(contentsOf: source), to: target)
        }
    }

    private func write(data: Data?, to target: URL) {
        guard let data else { return }
        do {
            try data.write(to: target, options: .atomic)
            onSaved(target)
        } catch {
            log.error("Could not save markup: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    /// Encodes the edited image in the format of the file it replaces, so a
    /// JPEG or HEIC screenshot keeps its format.
    private func encode(_ image: NSImage, like target: URL) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let type = UTType(filenameExtension: target.pathExtension) ?? .png
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cg, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
