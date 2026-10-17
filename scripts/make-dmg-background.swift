// Draws the background of the Cornerstack disk image window.
// Usage: swift scripts/make-dmg-background.swift out.png [scale]
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "background.png"
let scale = CGFloat(Double(CommandLine.arguments.dropFirst(2).first ?? "1") ?? 1)
let W: CGFloat = 600, H: CGFloat = 380

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// A pale version of the icon's blue, light so Finder labels stay legible.
NSGradient(colors: [color(226, 233, 255), color(236, 240, 255), color(246, 248, 255)],
           atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -35)

// Arrow from the app to Applications.
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 248, y: 190))
arrow.line(to: NSPoint(x: 344, y: 190))
arrow.lineWidth = 2.5
arrow.lineCapStyle = .round
color(110, 116, 140, 0.55).setStroke()
arrow.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 334, y: 199))
head.line(to: NSPoint(x: 346, y: 190))
head.line(to: NSPoint(x: 334, y: 181))
head.lineWidth = 2.5
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.stroke()

let style = NSMutableParagraphStyle(); style.alignment = .center
let text = NSAttributedString(string: "Drag Cornerstack to Applications", attributes: [
    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
    .foregroundColor: color(80, 84, 100),
    .paragraphStyle: style,
])
text.draw(in: NSRect(x: 0, y: 54, width: W, height: 20))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
