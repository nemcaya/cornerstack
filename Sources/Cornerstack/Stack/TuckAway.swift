import SwiftUI

/// Tucking away: left alone for a while, the stack slides off the edge of the
/// screen, and a small tab just above the corner shows how many cards wait
/// there. Pointing at the tab brings them back, and so do a new capture and
/// the show or hide shortcut. Nothing leaves the stack by tucking away.
///
/// The tab sits above the corner, not in it, so it never fights a Hot Corner
/// set there (Quick Note, by default).
enum TuckAway {
    /// The choices in Settings, in seconds; 0 is never.
    static let choices: [TimeInterval] = [0, 5, 10, 30]

    private static let key = "tuckDelay"

    /// How long the stack waits, with the pointer away from it, before it
    /// tucks away. 0 when it never does. On until you turn it off.
    static var delay: TimeInterval {
        get {
            guard UserDefaults.standard.object(forKey: key) != nil else { return 10 }
            return max(0, UserDefaults.standard.double(forKey: key))
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func title(for delay: TimeInterval) -> String {
        switch delay {
        case 0: L("Never")
        case 5: L("After 5 seconds")
        case 10: L("After 10 seconds")
        case 30: L("After 30 seconds")
        default: "\(Int(delay)) s"
        }
    }

    /// How long the pointer rests on the tab before the cards come back, so
    /// passing over it on the way somewhere else does nothing.
    static let revealDelay: TimeInterval = 0.12
}

/// The tab of a tucked stack: a narrow glass pill at the edge of the screen,
/// with an arrow and the number of cards.
struct TuckTab: View {
    let count: Int

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: "chevron.compact.left")
                .font(.system(size: 12, weight: .bold))
            Text(verbatim: "\(count)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(.primary)
        .frame(width: 22, height: 50)
        .glassFrame(capsule: true)
        .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
        .background(
            GeometryReader { g in
                Color.clear.preference(key: TabRectKey.self, value: g.frame(in: .global))
            }
        )
    }
}

struct TabRectKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}
