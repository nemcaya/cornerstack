import SwiftUI

/// One photo in the stack: a plain rounded thumbnail with a soft shadow,
/// like the macOS screenshot preview, that stays until you deal with it.
struct ShotView: View {
    let item: Shot
    @ObservedObject var stack: Stack

    @State private var arrived = false
    @State private var hovering = false

    private var badge: Badge? { stack.badge?.id == item.id ? stack.badge : nil }
    private var dragging: Bool { stack.draggingID == item.id }
    private var pressed: Bool { stack.pressedID == item.id }

    var body: some View {
        card
            // The fall itself is drawn over the whole screen by CaptureFlight,
            // so the card here just steps aside at once.
            .opacity(item.falling || item.flying ? 0 : (arrived ? 1 : 0))
            .transaction { t in if item.falling { t.animation = nil } }
            .animation(.easeOut(duration: 0.16), value: item.flying)
            .onAppear(perform: arrive)
    }

    /// The image fits the card keeping its proportions, so a wide screenshot
    /// is a wide card and a tall one a narrow card.
    private var cardSize: CGSize {
        let size = item.thumb.size
        let maxW = stack.cardWidth, maxH = Layout.maxCardHeight(stack.cardWidth)
        guard size.width > 0, size.height > 0 else { return CGSize(width: maxW, height: maxH) }
        let scale = min(maxW / size.width, maxH / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Layout.radius, style: .continuous)
    }

    private var card: some View {
        Image(nsImage: item.thumb)
            .resizable()
            .interpolation(.high)
            .frame(width: cardSize.width, height: cardSize.height)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.35), lineWidth: 0.75))
            .overlay(shape.stroke(Color.black.opacity(0.15), lineWidth: 0.5).padding(-0.5))
            .overlay {
                // A recording says so with a play button over its first frame.
                if item.isRecording {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 28, height: 28)
                        .glassFrame(circle: true)
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: .black.opacity(hovering ? 0.32 : 0.24), radius: hovering ? 14 : 10, y: hovering ? 6 : 4)
            // Holding presses the photo in slowly, so a long press feels like
            // it is building up to something.
            .scaleEffect(pressed ? 0.95 : (hovering ? 1.03 : 1))
            .animation(pressed ? .easeInOut(duration: 0.45) : .spring(response: 0.3, dampingFraction: 0.6), value: pressed)
            .opacity(dragging ? 0.45 : 1)
            .overlay(alignment: .topLeading) {
                // Drawn here, clicked through GrabView, which sits on top. A
                // kept card has no cross, so it can't be removed by accident.
                cornerButton("xmark", visible: hovering && !dragging && !item.kept)
            }
            .overlay(alignment: .topTrailing) {
                // The pin keeps a card on the stack. A kept card shows it all
                // the time; any other card on hover.
                cornerButton(item.kept ? "pin.fill" : "pin", visible: item.kept || (hovering && !dragging))
            }
            .overlay(GrabArea(item: item, stack: stack))
            .overlay {
                if let badge {
                    Label(badge.text, systemImage: badge.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassFrame(capsule: true)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.18), value: hovering)
            .animation(.easeOut(duration: 0.2), value: badge)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: item.kept)
            .onHover { hovering = $0 }
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: HitRectsKey.self,
                                           value: item.falling ? [:] : [item.id: g.frame(in: .global)])
                }
            )
    }

    /// A small glass button in a corner of the card, faded out until needed.
    private func cornerButton(_ symbol: String, visible: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.primary)
            .frame(width: 20, height: 20)
            .glassFrame(circle: true)
            .padding(3)
            .opacity(visible ? 1 : 0)
            .scaleEffect(visible ? 1 : 0.6)
            .allowsHitTesting(false)
    }

    private func arrive() {
        // A capture that flew in is already in place; the flight did the arriving.
        if item.flying {
            arrived = true
            return
        }
        withAnimation(.easeOut(duration: 0.25)) { arrived = true }
    }
}

extension View {
    /// A crisp glass: the system's blurred material with a thin specular
    /// edge, lit from above. Used for the small controls over a photo.
    func glassFrame(cornerRadius: CGFloat = 0, circle: Bool = false, capsule: Bool = false) -> some View {
        let shape: AnyShape = circle ? AnyShape(Circle())
            : capsule ? AnyShape(Capsule())
            : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        return background(.ultraThinMaterial, in: shape)
            .overlay(
                shape.stroke(
                    LinearGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0.12)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.75)
            )
            .overlay(shape.stroke(Color.black.opacity(0.10), lineWidth: 0.5).padding(-0.5))
    }
}
