import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Putting a capture on the clipboard, for the stack and for History.
enum Copying {
    /// Marks what Cornerstack itself puts on the clipboard, so "Add copied
    /// images" doesn't take it for a new image and add it to the stack again.
    static let ownType = NSPasteboard.PasteboardType("io.github.nemcaya.cornerstack.copy")

    /// The image and the file. A recording is copied as the file only, which
    /// apps paste as the video.
    static func copy(_ url: URL) {
        let entry = NSPasteboardItem()
        if !isRecording(url), let png = pngData(url) { entry.setData(png, forType: .png) }
        entry.setString(url.absoluteString, forType: .fileURL)
        entry.setData(Data(), forType: ownType)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([entry])
    }

    /// What Copy at 1x did.
    enum Result { case scaled, alreadyOneX, failed }

    /// The image at the size it had on screen: a Retina screenshot has two
    /// pixels for every point, so it pastes twice as big as it looked, with
    /// four times the pixels to send (and, for an AI chat, to pay for). This
    /// copies it at half the width and height. The file itself stays as it is
    /// and is not put on the clipboard, or apps would paste that instead.
    static func copyAtOneX(_ url: URL) -> Result {
        switch oneX(url) {
        case .png(let data):
            let entry = NSPasteboardItem()
            entry.setData(data, forType: .png)
            entry.setData(Data(), forType: ownType)
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([entry])
            return .scaled
        case .alreadyOneX:
            copy(url)
            return .alreadyOneX
        case .failed:
            return .failed
        }
    }

    enum OneX { case png(Data), alreadyOneX, failed }

    /// The 1x PNG for Copy at 1x, without touching the clipboard.
    static func oneX(_ url: URL) -> OneX {
        guard !isRecording(url), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return .failed }
        // macOS writes 144 dpi into a Retina screenshot: 2 pixels per point.
        let dpi = (properties[kCGImagePropertyDPIWidth] as? Double) ?? 72
        let scale = (dpi / 72).rounded()
        guard scale > 1 else { return .alreadyOneX }
        let longSide = Int((Double(max(width, height)) / scale).rounded())
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return .failed }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return .failed }
        // 72 dpi: one pixel per point, so apps show it at its own size.
        let oneX: [CFString: Any] = [kCGImagePropertyDPIWidth: 72, kCGImagePropertyDPIHeight: 72]
        CGImageDestinationAddImage(destination, image, oneX as CFDictionary)
        return CGImageDestinationFinalize(destination) ? .png(data as Data) : .failed
    }

    /// A PNG file goes on the clipboard as it is; any other image is
    /// converted straight from the file, keeping its resolution and colours.
    static func pngData(_ url: URL) -> Data? {
        if url.pathExtension.lowercased() == "png" { return try? Data(contentsOf: url) }
        let data = NSMutableData()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
