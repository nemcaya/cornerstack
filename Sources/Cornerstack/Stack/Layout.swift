import CoreGraphics
import Foundation

/// How wide the cards are. Automatic fits them to the screen the stack is on;
/// otherwise it is the width picked in Settings, where Small, Medium and
/// Large are shortcuts along the slider.
enum CardWidth {
    static let range: ClosedRange<CGFloat> = 140...320
    static let presets: [(name: String, width: CGFloat)] = [
        (L("Small"), 160), (L("Medium"), 200), (L("Large"), 260),
    ]

    private static let key = "cardWidth"

    /// The width picked in Settings, or nil for automatic.
    static var custom: CGFloat? {
        get {
            let value = CGFloat(UserDefaults.standard.double(forKey: key))
            return value > 0 ? value.clamped(to: range) : nil
        }
        set { UserDefaults.standard.set(newValue.map(Double.init) ?? 0, forKey: key) }
    }

    /// About a seventh of the screen's width: medium cards on a laptop,
    /// bigger ones on a large display.
    static func automatic(for visible: CGRect) -> CGFloat {
        (visible.width * 0.135).rounded().clamped(to: 160...280)
    }
}

/// The stack sits in the bottom right corner, above the Dock, like the
/// macOS screenshot preview. The newest card is closest to the corner and
/// pushes the older ones up.
enum Layout {
    static let gap: CGFloat = 10
    static let margin: CGFloat = 16
    static let radius: CGFloat = 10
    /// More than this and the oldest card leaves the stack (its file stays).
    static let maxItems = 5

    /// A card is as wide as the card width and at most this tall, so a
    /// screenshot keeps its proportions.
    static func maxCardHeight(_ width: CGFloat) -> CGFloat { (width * 0.65).rounded() }

    /// Room for the card, its margin and the hover shadow.
    static func panelWidth(_ cardWidth: CGFloat) -> CGFloat { cardWidth + margin * 2 + 12 }

    /// How many cards fit in a column this tall, at most `maxItems`, so large
    /// cards never run off the top of a small screen.
    static func capacity(cardWidth: CGFloat, height: CGFloat) -> Int {
        let fit = Int((height - margin + gap) / (maxCardHeight(cardWidth) + gap))
        return max(1, min(maxItems, fit))
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
