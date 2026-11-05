import SwiftUI

struct StackView: View {
    @ObservedObject var stack: Stack

    private var visible: [Shot] { stack.items.filter { !$0.falling } }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .trailing, spacing: Layout.gap) {
                Spacer(minLength: 0)
                if stack.items.isEmpty && stack.showsHint {
                    Hint().transition(.opacity)
                }
                // Oldest at the top, newest in the corner.
                ForEach(visible) { item in
                    ShotView(item: item, stack: stack)
                        .transition(.opacity)
                }
            }
            .padding(.trailing, Layout.margin)
            .padding(.bottom, Layout.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .animation(.spring(response: 0.3, dampingFraction: 0.86), value: visible.map(\.id))
            // Tucked away, the cards slide out past the edge of the screen.
            .offset(x: stack.isTucked ? Layout.panelWidth(stack.cardWidth) : 0)
            .opacity(stack.isTucked ? 0 : 1)

            if stack.isTucked && !visible.isEmpty {
                TuckTab(count: visible.count)
                    .padding(.trailing, 3)
                    .padding(.bottom, Layout.margin)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(stack.tuckSlides ? .spring(response: 0.42, dampingFraction: 0.86) : nil, value: stack.isTucked)
        .opacity(stack.isShown ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: stack.isShown)
        .onPreferenceChange(HitRectsKey.self) { rects in
            stack.hitRects = rects
        }
        .onPreferenceChange(TabRectKey.self) { rect in
            stack.tabRect = rect
        }
    }
}

private struct Hint: View {
    var body: some View {
        Text(L("Take a screenshot and it will land here"))
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
    }
}

struct HitRectsKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
