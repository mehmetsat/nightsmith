import SwiftUI

/// The line's controls, over the layers that draw it (`LineStage`): an invisible proxy at each print's resting place
/// takes clicks, hover and drags and carries its accessibility, and shows what hover and the keyboard bring up (the
/// caption pill, OCR chips, ⌘ numbers, focus, "Copied"). Around them: the basket tag at the right end of the rope, the
/// peek, the search capsule and the empty-line message. Nothing here moves on the drop; the prints do, in the stage.
struct LineView: View {
    @ObservedObject var state: ClotheslineState

    var body: some View {
        let layout = state.layout
        let width = layout.width
        let n = layout.prints.count
        let tagX = width - LineLayout.tagInset
        let down = state.dropped || LineMotion.reduced
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: width, height: 2)
                .offset(y: RopeCurve.anchor)
                .accessibilityElement()
                .accessibilityLabel("Clothesline rope")
                .accessibilityIdentifier("clotheslineRope")
            if state.hasBasketPull, state.peekID == nil {
                BasketTag(state: state)
                    .rotationEffect(.degrees(down ? 2 : -6), anchor: .top)
                    .animation(LineMotion.reduced ? nil : LineMotion.tagSwing.delay(down ? 0.12 : 0), value: down)
                    .opacity(down ? 1 : 0)
                    .animation(.easeOut(duration: down ? 0.18 : 0.1).delay(down ? 0.1 : 0), value: down)
                    .offset(x: tagX - BasketTag.width / 2, y: layout.rope.y(tagX) - BasketTag.ringY)
                    .transition(.opacity)
            }
            ForEach(layout.prints) { place in
                PrintProxy(state: state, place: place)
                    .zIndex(state.isLifted(place.id) ? 2 : 1)
            }
            if let c = state.peeked, let place = layout.place(c.id) {
                // Pulled forward from where it hangs, pegged to the same stretch of rope.
                let w = PeekMetrics.width(c)
                let x = PeekMetrics.x(centredOn: place.centre, c, lineWidth: width)
                let a = layout.rope.y(x + w * 0.12), b = layout.rope.y(x + w * 0.88)
                PeekPrint(state: state, capture: c, swing: Double(atan2(b - a, w * 0.76)) * 180 / .pi)
                    .offset(x: x, y: (a + b) / 2 + 4)
                    .transition(LineMotion.reduced ? .opacity : .scale(scale: 0.45, anchor: .top).combined(with: .opacity))
                    .zIndex(5)
            }
            if !state.query.isEmpty {
                SearchCapsule(state: state)
                    .frame(width: width)
                    .offset(y: n == 0 ? 150 : layout.lowest + 36)
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
                    .zIndex(3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .top) { if state.line.isEmpty { emptyLine } }
    }

    private var emptyLine: some View {
        VStack(spacing: 4) {
            if state.query.isEmpty {
                Text("Nothing on the line yet")
                    .font(.system(size: 13, weight: .medium))
                Text("Copy a screenshot with ⌘⌃⇧4 and it hangs here.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                Text("Nothing on the line matches “\(state.query)”")
                    .font(.system(size: 13, weight: .medium))
                Text(state.basket.isEmpty ? "Esc brings everything back." : "Older matches are in the basket below.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(ChipFill(cornerRadius: 12))
        .padding(.top, 60)
        .offset(y: state.dropped || LineMotion.reduced ? 0 : -40)
        .opacity(state.dropped ? 1 : 0)
        .animation(state.dropped ? .spring(response: LineMotion.dropResponse, dampingFraction: LineMotion.dropDamping)
                   : .easeIn(duration: LineMotion.retractDuration), value: state.dropped)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("clotheslineEmpty")
    }
}

/// The search, only once the user types: a 26 pt HUD capsule centred under the lowest print, with the query at 13 pt
/// and how many prints match.
struct SearchCapsule: View {
    @ObservedObject var state: ClotheslineState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
            HStack(spacing: 1) {
                Text(state.query)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .truncationMode(.head)
                Rectangle().fill(Color.accentColor).frame(width: 1.5, height: 14)
            }
            Text(count)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
            Button {
                state.clearQuery()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .buttonStyle(.plain)
            .help("Clear search (Esc)")
            .accessibilityIdentifier("clotheslineSearchClear")
        }
        .lineLimit(1)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 26)
        .frame(maxWidth: 360)
        .background(HUDFill())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search: \(state.query)")
        .accessibilityIdentifier("clotheslineSearch")
    }

    private var count: String {
        let n = state.line.filter { state.matchesSearch($0.id) }.count + state.basket.count
        return n == 1 ? "1 match" : "\(n) matches"
    }
}

/// A dark HUD capsule, painted rather than blurred so window capture shows it as it is.
struct HUDFill: View {
    var body: some View {
        Capsule()
            .fill(Color(white: 0.11).opacity(0.86))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
    }
}

/// The way into the basket: a 24 pt wicker basket hung from the right end of the rope on a wire hook, with an accent
/// badge counting the older captures waiting in it. Click it, rest on it, scroll down or press ↓ to open the basket;
/// open, its badge turns to a chevron to fold it away again.
struct BasketTag: View {
    static let width: CGFloat = 44
    /// Where the rope runs through the hook, from the top of the view.
    static let ringY: CGFloat = 2
    @ObservedObject var state: ClotheslineState
    @Environment(\.colorScheme) private var scheme
    @State private var dwell: DispatchWorkItem?
    @State private var hovering = false

    var body: some View {
        Button {
            state.setBasket(!state.basketOpen)
        } label: {
            VStack(spacing: 0) {
                // The hook over the rope and the wire down to the handle.
                HookShape()
                    .stroke(LinearGradient(colors: [Color(white: 0.92), Color(white: 0.5)], startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                    .frame(width: 8, height: 9)
                    .accessibilityElement()
                    .accessibilityLabel("Basket cord")
                    .accessibilityIdentifier("clotheslinePullCord")
                Wicker()
                    .frame(width: 30, height: 24)
                    .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.22), radius: hovering ? 5 : 3, y: hovering ? 4 : 2)
                    .overlay(alignment: .topTrailing) { badge.offset(x: 9, y: 2) }
                    .accessibilityIdentifier("clotheslineBasket")
            }
            .scaleEffect(hovering ? 1.06 : 1, anchor: .top)
            .frame(width: Self.width)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.interpolatingSpring(stiffness: 400, damping: 28)) { hovering = inside }
            dwell?.cancel()
            guard inside, !state.basketOpen else { return }
            let work = DispatchWorkItem { state.setBasket(true) }
            dwell = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
        .help(state.basketOpen ? "Fold the basket away (↑)" : "\(state.olderCount) older captures (↓)")
        .accessibilityLabel(state.basketOpen ? "Fold the basket away" : "Open the basket, \(state.olderCount) older")
        .accessibilityIdentifier("clotheslineBasketTab")
    }

    /// The count, or a chevron while the basket is open: white on the accent colour, with a paper rim.
    private var badge: some View {
        Group {
            if state.basketOpen {
                Image(systemName: "chevron.up").font(.system(size: 8, weight: .heavy))
            } else {
                Text(verbatim: state.olderCount > 999 ? "999+" : "\(state.olderCount)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 4)
        .frame(minWidth: 16, minHeight: 16)
        .background(Capsule().fill(Color.accentColor))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.9), lineWidth: 1))
        .fixedSize()
        .accessibilityIdentifier("clotheslineBasketCount")
    }
}

/// A small wicker basket, 30 × 24 pt: a woven handle, a rim, and a body narrower at the foot with rows of weave.
private struct Wicker: View {
    var body: some View {
        let cane = Color(red: 0.79, green: 0.62, blue: 0.39)
        let deep = Color(red: 0.55, green: 0.39, blue: 0.2)
        ZStack(alignment: .top) {
            // Handle.
            Ellipse()
                .trim(from: 0.5, to: 1)
                .stroke(LinearGradient(colors: [cane, deep], startPoint: .top, endPoint: .bottom), lineWidth: 2)
                .frame(width: 20, height: 18)
                .offset(y: 0)
            // Body.
            BasketBody()
                .fill(LinearGradient(colors: [cane, deep], startPoint: .top, endPoint: .bottom))
                .overlay {
                    Canvas { ctx, size in
                        // Rows of weave, and the uprights they are woven through.
                        for k in 1..<4 {
                            let y = size.height * CGFloat(k) / 4
                            var p = Path()
                            p.move(to: CGPoint(x: 0, y: y))
                            p.addLine(to: CGPoint(x: size.width, y: y))
                            ctx.stroke(p, with: .color(.black.opacity(0.22)), lineWidth: 0.6)
                        }
                        for k in 1..<6 {
                            let x = size.width * CGFloat(k) / 6
                            var p = Path()
                            p.move(to: CGPoint(x: x, y: 0))
                            p.addLine(to: CGPoint(x: x + (x - size.width / 2) * -0.12, y: size.height))
                            ctx.stroke(p, with: .color(.white.opacity(0.18)), lineWidth: 0.6)
                        }
                    }
                    .clipShape(BasketBody())
                }
                .overlay(BasketBody().stroke(deep.opacity(0.8), lineWidth: 0.5))
                .frame(width: 30, height: 15)
                .offset(y: 9)
            // Rim.
            Capsule()
                .fill(LinearGradient(colors: [Color(red: 0.88, green: 0.73, blue: 0.5), cane], startPoint: .top, endPoint: .bottom))
                .overlay(Capsule().stroke(deep.opacity(0.7), lineWidth: 0.5))
                .frame(width: 32, height: 3.5)
                .offset(y: 7.5)
        }
        .frame(width: 30, height: 24)
    }
}

private struct BasketBody: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - 3.5, y: r.maxY - 2))
        p.addQuadCurve(to: CGPoint(x: r.maxX - 5.5, y: r.maxY), control: CGPoint(x: r.maxX - 4, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + 5.5, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX + 3.5, y: r.maxY - 2), control: CGPoint(x: r.minX + 4, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// An S-hook: over the rope at the top, down to the basket's handle.
private struct HookShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + 1, y: r.minY + 4))
        p.addQuadCurve(to: CGPoint(x: r.midX + 1, y: r.minY + 4), control: CGPoint(x: r.midX - 1, y: r.minY - 2.5))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        return p
    }
}
