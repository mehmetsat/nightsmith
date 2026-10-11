import AppKit
import SwiftUI

/// Sizes of a print pulled forward to be read. The image is as large as the space under the line allows, aspect kept.
enum PeekMetrics {
    static let maxImageHeight: CGFloat = 400
    static let maxImageWidth: CGFloat = 720
    static let border: CGFloat = 10
    /// Kept clear at either screen edge.
    static let edge: CGFloat = 20

    static func imageSize(_ c: Capture) -> CGSize {
        guard c.width > 0, c.height > 0 else { return CGSize(width: maxImageWidth, height: maxImageWidth / 1.6) }
        let aspect = CGFloat(c.width) / CGFloat(c.height)
        var h = min(maxImageHeight, CGFloat(c.height))
        var w = h * aspect
        if w > maxImageWidth {
            w = maxImageWidth
            h = w / aspect
        }
        return CGSize(width: w.rounded(), height: h.rounded())
    }

    static func width(_ c: Capture) -> CGFloat { imageSize(c).width + 2 * border }

    /// Left edge of the peek: centred under the print it came from, slid along so it stays on screen.
    static func x(centredOn mid: CGFloat, _ c: Capture, lineWidth: CGFloat) -> CGFloat {
        let w = width(c)
        return min(max(mid - w / 2, edge), max(lineWidth - edge - w, edge))
    }
}

/// A print pulled towards the viewer at full size: the same paper, pegged to the same spot on the rope, large enough to
/// read the text in a real screenshot. Space or Esc puts it back; a click copies it and the line tucks away.
struct PeekPrint: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var state: ClotheslineState
    @Environment(\.colorScheme) private var scheme
    let capture: Capture
    let swing: Double

    @State private var image: NSImage?

    init(state: ClotheslineState, capture: Capture, swing: Double) {
        self.state = state
        self.capture = capture
        self.swing = swing
        let size = PeekMetrics.imageSize(capture)
        _image = State(initialValue: PrintImages.cached(state.store.imageURL(capture), maxPixel: Self.pixels(size))
            ?? Images.cached(state.store.thumbURL(capture)))
    }

    private static func pixels(_ size: CGSize) -> Int { Int(max(size.width, size.height) * 2) }
    private var style: PaperStyle { PaperStyle(scheme: scheme) }
    private var size: CGSize { PeekMetrics.imageSize(capture) }
    private var copied: Bool { state.copiedID == capture.id }
    private var chips: [String] { Array(Identifiers.find(in: capture.ocrText).prefix(4)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                style.bay
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).antialiased(true)
                        .aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
            caption
                .padding(.top, 8)
                .padding(.bottom, 10)
                .padding(.horizontal, 2)
        }
        .padding([.top, .horizontal], PeekMetrics.border)
        .frame(width: PeekMetrics.width(capture), alignment: .leading)
        .background(paper)
        .overlay {
            if copied {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(-3)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topLeading) { fasteners }
        .rotationEffect(.degrees(swing), anchor: .top)
        .contentShape(Rectangle())
        .onTapGesture {
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                model.openInPreview(capture)
                model.clothesline.hide(restoreFocus: false)
            } else if state.copiedID == nil {
                model.copy(capture, hud: true)
                state.markCopied(capture.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + LineMotion.copiedHold) { model.hideClothesline() }
            }
        }
        .onDrag {
            state.takenID = capture.id
            return NSItemProvider(contentsOf: model.engine.store.imageURL(capture)) ?? NSItemProvider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Peek: \(Fmt.stamp(capture.created)), \(capture.width) × \(capture.height)")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("peg-peek-\(capture.id)")
        .task(id: capture.id) {
            if let sharp = await PrintImages.load(model.engine.store.imageURL(capture), maxPixel: Self.pixels(size)) {
                image = sharp
            }
        }
    }

    private var paper: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(style.paper)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.12), radius: 1, y: 1)
            .shadow(color: .black.opacity(scheme == .dark ? 0.55 : 0.26), radius: 30, x: 4, y: 22)
    }

    /// Where, when and how big on the left; what a click does on the right. Chips copy just their text.
    private var caption: some View {
        HStack(alignment: .center, spacing: 8) {
            if let app = capture.app, !app.isEmpty {
                HStack(spacing: 5) {
                    Circle().fill(PegPaint.accent(for: app)).frame(width: 7, height: 7)
                    Text(app).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(style.ink)
                }
            }
            Text(Fmt.stamp(capture.created))
                .font(.system(size: 11.5, weight: capture.app == nil ? .semibold : .regular))
                .foregroundStyle(capture.app == nil ? style.ink : style.faintInk)
            Text(verbatim: "\(capture.width) × \(capture.height)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(style.faintInk)
            ForEach(Array(chips.enumerated()), id: \.offset) { i, t in chip(t, i) }
            Spacer(minLength: 6)
            Text(copied ? "Copied" : "Click to copy  ·  Space to put back")
                .font(.system(size: 11, weight: copied ? .semibold : .medium))
                .foregroundStyle(copied ? Color.accentColor : style.faintInk)
                .accessibilityIdentifier("peg-peek-hint")
        }
        .lineLimit(1)
        .frame(height: 20)
    }

    private func chip(_ text: String, _ index: Int) -> some View {
        Button {
            model.engine.copyText(text)
            model.showToast("Copied “\(OCRChip.label(text))”", hud: true)
            model.hideClothesline()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: OCRChip.symbol(text)).font(.system(size: 8.5, weight: .bold)).foregroundStyle(OCRChip.tint(text))
                Text(OCRChip.label(text)).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(style.ink)
                    .fixedSize()
            }
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(Capsule().fill(Color.black.opacity(0.04)))
            .overlay(Capsule().strokeBorder(OCRChip.tint(text).opacity(0.45), lineWidth: 0.6))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Copy \(text)")
        .accessibilityLabel("Copy \(text)")
        .accessibilityIdentifier("peg-peek-chip-\(index)")
    }

    /// The same pegs as on the line, at their own size: the print is closer, the hardware is not bigger.
    @ViewBuilder private var fasteners: some View {
        let w = PeekMetrics.width(capture)
        if capture.pinned {
            SteelClip()
                .shadow(color: .black.opacity(0.32), radius: 1.2, y: 1)
                .offset(x: (w - SteelClip.size.width) / 2, y: -4 - SteelClip.ropeY)
        } else {
            ZStack(alignment: .topLeading) {
                ForEach(Array([w * 0.12, w * 0.88].enumerated()), id: \.offset) { i, x in
                    WoodPeg(seed: Int(capture.id) &+ 7 &+ i)
                        .shadow(color: .black.opacity(0.3), radius: 0.6, y: 1)
                        .offset(x: x - WoodPeg.size.width / 2, y: -4 - WoodPeg.ropeY)
                }
            }
            .accessibilityHidden(true)
        }
    }
}
