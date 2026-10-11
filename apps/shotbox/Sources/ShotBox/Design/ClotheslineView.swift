import SwiftUI

enum StripMetrics {
    /// The line on the widest screen: rope, prints, the room they swing in, the hover caption and the search under
    /// them. On a given screen the line takes `RopeCurve.lineHeight(width:)` of it.
    static let maxLineHeight: CGFloat = 400
    static let basketHeight: CGFloat = 330
    /// The window is always this tall; the basket opens inside it and the empty part is clear.
    static let panelHeight: CGFloat = maxLineHeight + basketHeight
}

/// The surface's controls, laid over the line's layers (`LineStage`), which sit in the same window underneath. No
/// backdrop slab: the prints float over the wallpaper on their paper, two shadows and a soft scrim that the stage
/// paints from the menubar down past the prints and fades to nothing. Pulled further down, the basket of older captures opens below.
/// The tree is built once and stays built while hidden; opening changes nothing here but `dropped`.
struct ClotheslineView: View {
    @ObservedObject var state: ClotheslineState

    var body: some View {
        let reduced = LineMotion.reduced
        ZStack(alignment: .top) {
            // Clear, but it takes the click: a click on nothing tucks the line away.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { state.onBackgroundTap?() }
                .accessibilityHidden(true)
                .accessibilityIdentifier("clotheslineScrim")
            Color.clear
                .frame(height: 200)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .accessibilityIdentifier("clotheslineBackdrop")
            VStack(spacing: 0) {
                LineView(state: state)
                    .frame(height: state.lineHeight)
                ZStack(alignment: .top) {
                    if state.basketOpen {
                        BasketView(state: state)
                            .transition(reduced
                                ? .opacity
                                : .opacity.combined(with: .offset(y: -40)).combined(with: .scale(scale: 0.97, anchor: .top)))
                    }
                }
                .frame(height: StripMetrics.basketHeight, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(state.visible ? 1 : 0)
        .allowsHitTesting(state.visible && !state.retracting)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Clothesline")
        .accessibilityIdentifier("clotheslineStrip")
    }
}

/// The fill small controls on the line use, in place of a system material: near-opaque paper with a hairline.
struct ChipFill: View {
    @Environment(\.colorScheme) private var scheme
    var cornerRadius: CGFloat? = nil

    var body: some View {
        let dark = scheme == .dark
        let shape = RoundedRectangle(cornerRadius: cornerRadius ?? 999, style: .continuous)
        shape
            .fill(dark ? Color(white: 0.2).opacity(0.94) : Color.white.opacity(0.95))
            .overlay(shape.strokeBorder(dark ? Color.white.opacity(0.12) : Color.black.opacity(0.1), lineWidth: 0.5))
            .shadow(color: .black.opacity(dark ? 0.35 : 0.12), radius: 4, y: 1.5)
    }
}
