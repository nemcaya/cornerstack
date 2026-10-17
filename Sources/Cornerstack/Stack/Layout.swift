import CoreGraphics

/// The stack sits in the bottom right corner, above the Dock, like the
/// macOS screenshot preview. The newest card is closest to the corner and
/// pushes the older ones up.
enum Layout {
    static let cardWidth: CGFloat = 200
    static let maxCardHeight: CGFloat = 130
    static let gap: CGFloat = 10
    static let margin: CGFloat = 16
    /// Room for the card, its margin and the hover shadow.
    static let panelWidth: CGFloat = cardWidth + margin * 2 + 12
    static let radius: CGFloat = 10
    /// More than this and the oldest card leaves the stack (its file stays).
    static let maxItems = 5
}
