import AppKit
import QuartzCore

/// Reads where on screen a screenshot was taken. macOS stores the captured
/// area on the file, in global points with the origin at the top left of
/// the main display. Returned in AppKit screen coordinates.
func captureRect(of url: URL) -> CGRect? {
    let name = "com.apple.metadata:kMDItemScreenCaptureGlobalRect"
    let data: Data? = url.withUnsafeFileSystemRepresentation { path in
        guard let path else { return nil }
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = Data(count: size)
        let read = buffer.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
        return read == size ? buffer : nil
    }
    guard let data,
          let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [NSNumber],
          values.count == 4, let main = NSScreen.screens.first else { return nil }
    let x = CGFloat(truncating: values[0]), y = CGFloat(truncating: values[1])
    let w = CGFloat(truncating: values[2]), h = CGFloat(truncating: values[3])
    guard w > 2, h > 2 else { return nil }
    return CGRect(x: x, y: main.frame.maxY - y - h, width: w, height: h)
}

/// The capture lifting off the screen and flying into the stack. It turns
/// into the card on the way: it shrinks and rounds its corners, so there is
/// nothing left to change on landing.
@MainActor
final class CaptureFlight {
    static let duration: CFTimeInterval = 0.34
    /// How high the gentle arc rises halfway, in points.
    private static let arc: CGFloat = 30

    private let window: NSWindow
    private let container = CALayer()
    private let photo = CALayer()

    private let from: CGRect
    private let to: CGRect
    private var falling = false
    private var duration: CFTimeInterval = CaptureFlight.duration
    private var start: CFTimeInterval = 0
    private var timer: Timer?
    private var completion: () -> Void = {}

    private static var current: [CaptureFlight] = []

    /// Captures flying to the stack right now. Each one holds a large image,
    /// so in a burst of captures only a couple fly and the rest drop in.
    static var flightsInProgress: Int { current.filter { !$0.falling }.count }

    /// - Parameters:
    ///   - from: the captured area, in screen coordinates.
    ///   - to: the card's frame on the stack, in screen coordinates.
    static func fly(image: CGImage, from: CGRect, to: CGRect, on screen: NSScreen,
                    completion: @escaping () -> Void) {
        let flight = CaptureFlight(image: image, from: from, to: to, screen: screen)
        current.append(flight)
        flight.completion = { [weak flight] in
            completion()
            current.removeAll { $0 === flight }
        }
        flight.run()
    }

    /// A card leaving the stack falls off, drawn over the whole screen so
    /// it is never clipped by the stack panel. It drops 520 points, tilting and
    /// fading, over 0.55 s.
    static func fall(image: CGImage, card: CGRect, on screen: NSScreen) {
        let flight = CaptureFlight(image: image, from: card, to: card, screen: screen)
        flight.falling = true
        flight.duration = 0.55
        current.append(flight)
        flight.completion = { [weak flight] in current.removeAll { $0 === flight } }
        flight.run()
    }

    private init(image: CGImage, from: CGRect, to: CGRect, screen: NSScreen) {
        self.from = from
        self.to = to
        window = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.sharingType = .none
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let host = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        host.wantsLayer = true
        window.contentView = host
        let scale = screen.backingScaleFactor

        container.anchorPoint = CGPoint(x: 0.5, y: 1)   // the card's top center
        container.shadowColor = NSColor.black.cgColor
        container.shadowOpacity = 0.24
        container.shadowRadius = 10
        container.shadowOffset = CGSize(width: 0, height: -5)

        photo.contents = image
        photo.contentsGravity = .resizeAspectFill
        photo.masksToBounds = true

        for layer in [container, photo] { layer.contentsScale = scale }
        container.addSublayer(photo)
        host.layer?.addSublayer(container)
    }

    private func run() {
        if falling { update(1); updateFall(0) } else { update(0) }
        window.orderFrontRegardless()
        start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let k = min(1, (CACurrentMediaTime() - start) / duration)
        if falling { updateFall(k) } else { update(k) }
        guard k >= 1 else { return }
        timer?.invalidate()
        timer = nil
        completion()
        if falling {
            window.orderOut(nil)
            return
        }
        // The real card fades in underneath; this one fades out over it.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            window.animator().alphaValue = 0
        }, completionHandler: { [window] in
            MainActor.assumeIsolated { window.orderOut(nil) }
        })
    }

    private func updateFall(_ raw: Double) {
        let e = CGFloat(raw * raw * raw)
        let origin = window.frame.origin
        let angle = 20 * e
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.position = CGPoint(x: to.midX - origin.x, y: to.maxY - origin.y - 520 * e)
        container.setAffineTransform(CGAffineTransform(rotationAngle: -angle * .pi / 180))
        container.opacity = Float(1 - e)
        CATransaction.commit()
    }

    private static func easeInOutCubic(_ x: Double) -> Double {
        x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    private func update(_ raw: Double) {
        let k = CGFloat(Self.easeInOutCubic(raw))
        let origin = window.frame.origin
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * k }

        let w = lerp(from.width, to.width), h = lerp(from.height, to.height)
        let topX = lerp(from.midX, to.midX) - origin.x
        let topY = lerp(from.maxY, to.maxY) - origin.y + sin(.pi * k) * Self.arc
        let radius = lerp(0, Layout.radius)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        container.position = CGPoint(x: topX, y: topY)
        container.shadowPath = CGPath(roundedRect: container.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        photo.frame = container.bounds
        photo.cornerRadius = radius
        CATransaction.commit()
    }
}
