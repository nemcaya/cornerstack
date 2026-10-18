import AppKit
import AVFoundation

/// Screen recordings, as macOS saves them.
func isRecording(_ url: URL) -> Bool {
    ["mov", "mp4"].contains(url.pathExtension.lowercased())
}

/// Cards are drawn from an image this many pixels on its long side: twice the
/// widest card, so every card size stays sharp on a Retina screen, and no
/// more, since every card keeps its image in memory.
private let cardPixels = Int(CardWidth.range.upperBound * 2)

/// A new capture, decoded once: the card's image, and a bigger one for its
/// flight when it has one. Safe to make off the main thread.
struct CaptureImages {
    let card: NSImage
    let flight: CGImage?
}

/// `flightPixels` is the size the flight starts out at, or nil for a capture
/// that doesn't fly in.
func loadCapture(_ url: URL, flightPixels: Int?) -> CaptureImages? {
    guard let image = decodeImage(url, maxPixels: max(flightPixels ?? 0, cardPixels)) else { return nil }
    return CaptureImages(card: cardImage(from: image), flight: flightPixels == nil ? nil : image)
}

/// The card's image for a file already on disk, for example after Markup.
func makeThumbnail(_ url: URL) -> NSImage? {
    decodeImage(url, maxPixels: cardPixels).map(cardImage(from:))
}

private func cardImage(from image: CGImage) -> NSImage {
    let card = downscale(image, maxPixels: cardPixels)
    return NSImage(cgImage: card, size: NSSize(width: card.width, height: card.height))
}

/// A screenshot decoded straight to the size asked for; a recording shows
/// its first frame.
private func decodeImage(_ url: URL, maxPixels: Int) -> CGImage? {
    if isRecording(url) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
        return try? generator.copyCGImage(at: .zero, actualTime: nil)
    }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

/// Scales an already decoded image down, without reading the file again.
private func downscale(_ image: CGImage, maxPixels: Int) -> CGImage {
    let longSide = max(image.width, image.height)
    guard longSide > maxPixels else { return image }
    let scale = CGFloat(maxPixels) / CGFloat(longSide)
    let width = Int((CGFloat(image.width) * scale).rounded())
    let height = Int((CGFloat(image.height) * scale).rounded())
    // Keep the screenshot's own colour space when it is RGB (sRGB, Display P3);
    // anything else, like grayscale, is drawn into sRGB.
    let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return image
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage() ?? image
}
