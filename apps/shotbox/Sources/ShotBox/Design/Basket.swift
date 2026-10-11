import AppKit
import SwiftUI

/// The basket under the line: the rest of the library, newest first, lying loose like prints taken off the line.
/// Same library as the main window; a click copies and tucks everything away.
struct BasketView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var state: ClotheslineState

    static let itemWidth: CGFloat = 148
    static let spacing: CGFloat = 18
    static let inset: CGFloat = 24
    /// Two rows show at once; more scroll inside the tray.
    static let rowHeight: CGFloat = 150

    static func width(columns: Int) -> CGFloat {
        CGFloat(columns) * itemWidth + CGFloat(columns - 1) * spacing + 2 * inset
    }

    var body: some View {
        let cols = state.basketColumns
        let grid = [GridItem](repeating: GridItem(.fixed(Self.itemWidth), spacing: Self.spacing), count: cols)
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Self.inset + 2)
                .padding(.top, 18)
                .padding(.bottom, 8)
            if state.basket.isEmpty {
                empty
            } else if state.basket.count <= cols * 2 {
                // Few enough to lie flat: no scroller, and the tray is only as deep as its prints.
                LazyVGrid(columns: grid, spacing: Self.spacing) { prints }
                    .padding(.horizontal, Self.inset)
                    .padding(.top, 6)
                    .padding(.bottom, 20)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVGrid(columns: grid, spacing: Self.spacing) { prints }
                        .padding(.horizontal, Self.inset)
                        .padding(.top, 6)
                        .padding(.bottom, 20)
                }
                .frame(height: Self.rowHeight * 2 + 20)
            }
        }
        .frame(width: Self.width(columns: cols), alignment: .leading)
        .clipShape(BasketShape())
        .background { BasketSheet() }
        .overlay(alignment: .top) {
            // The cane rim runs a little wider than the tray, like the lip of a real basket.
            WovenRim()
                .frame(height: 9)
                .padding(.horizontal, -6)
                .offset(y: -3)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clotheslineBasket")
    }

    private var prints: some View {
        ForEach(state.basket) { c in
            BasketPrint(state: state, capture: c)
                .transition(.opacity.combined(with: .scale(scale: 0.94)))
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Basket")
                .font(.system(size: 13, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button {
                model.clothesline.hide(restoreFocus: false)
                model.showMainWindow()
            } label: {
                HStack(spacing: 4) {
                    Text("Open Library")
                    Text("⌃⌥⌘S").foregroundStyle(.tertiary)
                }
                .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .accessibilityIdentifier("basketOpenLibrary")
        }
    }

    private var subtitle: String {
        let n = state.basket.count
        if !state.query.isEmpty {
            return n == 1 ? "1 older match for “\(state.query)”" : "\(n) older matches for “\(state.query)”"
        }
        return n == 1 ? "1 older capture" : "\(n) older captures"
    }

    private var empty: some View {
        Text(state.query.isEmpty ? "Nothing older yet. Captures move here as new ones are pegged on the line."
                                 : "No older captures match “\(state.query)”.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
            .padding(.bottom, 30)
            .accessibilityIdentifier("basketEmpty")
    }
}

/// The tray: square shoulders under the rim, generously rounded at the bottom.
struct BasketShape: Shape {
    func path(in r: CGRect) -> Path {
        UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 22, bottomTrailingRadius: 22,
                               topTrailingRadius: 6, style: .continuous).path(in: r)
    }
}

/// A print lying in the basket: smaller, unpegged, a touch askew.
struct BasketPrint: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var state: ClotheslineState
    @Environment(\.colorScheme) private var scheme
    let capture: Capture

    @State private var thumb: NSImage?

    init(state: ClotheslineState, capture: Capture) {
        self.state = state
        self.capture = capture
        _thumb = State(initialValue: Images.cached(state.store.thumbURL(capture)))
    }

    private var lifted: Bool { state.hoveredID == capture.id }
    private var style: PaperStyle { PaperStyle(scheme: scheme) }
    private var tilt: Double { PrintMetrics.naturalTilt(capture) * 0.45 }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                style.bay
                if let thumb {
                    Image(nsImage: thumb).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                }
            }
            .frame(height: 92)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(Fmt.stamp(capture.created))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(style.ink)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Circle().fill(PegPaint.accent(for: capture.app)).frame(width: 5, height: 5)
                    Text(verbatim: "\(capture.width) × \(capture.height)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(style.faintInk)
                        .lineLimit(1)
                    if capture.pinned {
                        Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(style.faintInk)
                    }
                }
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(style.paper)
                .shadow(color: .black.opacity(lifted ? 0.28 : 0.14), radius: lifted ? 12 : 3, y: lifted ? 8 : 2)
        )
        .scaleEffect(lifted ? 1.05 : 1)
        .rotationEffect(.degrees(lifted ? 0 : tilt))
        .zIndex(lifted ? 1 : 0)
        .contentShape(Rectangle())
        .onHover { state.hover(capture.id, $0) }
        .onTapGesture(count: 2) {
            model.openInPreview(capture)
            model.clothesline.hide(restoreFocus: false)
        }
        .onTapGesture { choose() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(Fmt.stamp(capture.created)), \(capture.width) × \(capture.height)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { choose() }
        .accessibilityIdentifier("basket-card-\(capture.id)")
        .task(id: capture.id) {
            if thumb == nil { thumb = await Images.load(model.engine.store.thumbURL(capture)) }
        }
    }

    private func choose() {
        model.copy(capture, hud: true)
        model.hideClothesline()
    }
}

/// The basket's rim: a band of woven cane, the only ornament on the surface.
struct WovenRim: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { ctx, size in
            let light = scheme == .dark ? Color(red: 0.62, green: 0.50, blue: 0.36) : Color(red: 0.85, green: 0.72, blue: 0.53)
            let dark = scheme == .dark ? Color(red: 0.45, green: 0.36, blue: 0.26) : Color(red: 0.70, green: 0.56, blue: 0.39)
            let band = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
            ctx.fill(band, with: .color(dark))
            ctx.clip(to: band)
            let step: CGFloat = 9
            var x: CGFloat = 0
            var row = 0
            while x < size.width {
                for half in 0..<2 {
                    let y = CGFloat(half) * size.height / 2
                    let shift: CGFloat = (row + half).isMultiple(of: 2) ? 0 : step / 2
                    let r = CGRect(x: x + shift + 0.5, y: y + 0.5, width: step / 2 - 1, height: size.height / 2 - 1)
                    ctx.fill(Path(roundedRect: r, cornerRadius: 1.5), with: .color(light))
                }
                x += step
                row += 1
            }
        }
        .opacity(0.9)
        .accessibilityHidden(true)
    }
}

/// The basket's body, painted rather than blurred: woven linen, near-opaque, a shade deeper at the bottom as if the
/// prints lie inside it, with a faint diagonal weave, a hairline edge and a soft shadow on the screen below.
struct BasketSheet: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let shape = BasketShape()
        let top = dark ? Color(red: 0.19, green: 0.175, blue: 0.16) : Color(red: 0.975, green: 0.965, blue: 0.945)
        let bottom = dark ? Color(red: 0.13, green: 0.12, blue: 0.11) : Color(red: 0.925, green: 0.905, blue: 0.87)
        shape
            .fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
            .overlay {
                Canvas { ctx, size in
                    var weave = Path()
                    var x: CGFloat = -size.height
                    while x < size.width {
                        weave.move(to: CGPoint(x: x, y: size.height))
                        weave.addLine(to: CGPoint(x: x + size.height, y: 0))
                        x += 7
                    }
                    ctx.stroke(weave, with: .color(dark ? .white.opacity(0.025) : Color(red: 0.5, green: 0.4, blue: 0.25).opacity(0.05)),
                               lineWidth: 2.5)
                }
                .clipShape(shape)
            }
            .opacity(0.97)
            .overlay(shape.stroke(dark ? Color.white.opacity(0.1) : Color(red: 0.45, green: 0.36, blue: 0.24).opacity(0.18), lineWidth: 0.6))
            .shadow(color: .black.opacity(dark ? 0.5 : 0.2), radius: 24, y: 12)
            .accessibilityHidden(true)
    }
}
