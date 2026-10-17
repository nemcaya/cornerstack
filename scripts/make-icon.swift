// Draws the Cornerstack app icon: three screenshots stacked toward the
// bottom right corner, over a deep blue gradient.
// Usage: swift scripts/make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// Body, following the macOS icon grid: 824pt square, 100pt margin.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

ctx.saveGState()
let drop = NSShadow()
drop.shadowColor = color(8, 12, 40, 0.45)
drop.shadowBlurRadius = 26
drop.shadowOffset = NSSize(width: 0, height: -12)
drop.set()
color(30, 50, 130).setFill()
shape.fill()
ctx.restoreGState()

ctx.saveGState()
shape.addClip()
NSGradient(colors: [color(70, 110, 255), color(40, 60, 200), color(22, 28, 96)],
           atLocations: [0, 0.5, 1], colorSpace: .sRGB)!.draw(in: body, angle: -55)
// Soft light from the top left.
NSGradient(colors: [color(255, 255, 255, 0.28), color(255, 255, 255, 0)])!
    .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)

// Three cards, the newest nearest the bottom right and each older one up and
// to the left. The group is centred on the body, nudged up a little so the
// shadows below it do not make it look low.
let cardSize = NSSize(width: 420, height: 290)
let step = NSPoint(x: -64, y: 92)             // offset of each older card
let group = NSSize(width: cardSize.width - step.x * 2, height: cardSize.height + step.y * 2)
let center = NSPoint(x: body.midX, y: body.midY + 10)
let newest = NSPoint(x: center.x + group.width / 2 - cardSize.width, y: center.y - group.height / 2)
let tints: [(NSColor, NSColor)] = [
    (color(190, 205, 255), color(150, 170, 245)),
    (color(215, 225, 255), color(175, 195, 250)),
    (color(255, 255, 255), color(205, 218, 255)),
]
for i in 0..<3 {
    let n = CGFloat(2 - i)                    // 2 = oldest, 0 = newest
    let origin = NSPoint(x: newest.x + step.x * n, y: newest.y + step.y * n)
    let rect = NSRect(origin: origin, size: cardSize)
    let card = NSBezierPath(roundedRect: rect, xRadius: 44, yRadius: 44)
    ctx.saveGState()
    let s = NSShadow()
    s.shadowColor = color(8, 12, 50, 0.38)
    s.shadowBlurRadius = 30
    s.shadowOffset = NSSize(width: 0, height: -14)
    s.set()
    tints[i].0.setFill()
    card.fill()
    ctx.restoreGState()

    ctx.saveGState()
    card.addClip()
    NSGradient(starting: tints[i].0, ending: tints[i].1)!.draw(in: rect, angle: -60)
    // A tiny landscape so each card reads as a picture.
    let hill = NSBezierPath()
    hill.move(to: NSPoint(x: rect.minX, y: rect.minY))
    hill.line(to: NSPoint(x: rect.minX, y: rect.minY + 80))
    hill.curve(to: NSPoint(x: rect.maxX, y: rect.minY + 60),
               controlPoint1: NSPoint(x: rect.minX + 150, y: rect.minY + 150),
               controlPoint2: NSPoint(x: rect.minX + 270, y: rect.minY + 10))
    hill.line(to: NSPoint(x: rect.maxX, y: rect.minY))
    hill.close()
    color(70, 100, 230, 0.35).setFill()
    hill.fill()
    color(255, 255, 255, 0.85).setFill()
    NSBezierPath(ovalIn: NSRect(x: rect.maxX - 120, y: rect.maxY - 100, width: 56, height: 56)).fill()
    ctx.restoreGState()

    color(255, 255, 255, 0.7).setStroke()
    card.lineWidth = 3
    card.stroke()
}
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
