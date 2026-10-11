import AppKit
import ImageIO
import SwiftUI

/// The paper of a print. White in both appearances, so the screenshot reads over any wallpaper; only the shadows
/// deepen in dark mode.
struct PaperStyle {
    let scheme: ColorScheme
    var dark: Bool { scheme == .dark }
    var paper: Color { dark ? Color(red: 0.95, green: 0.945, blue: 0.935) : .white }
    var bay: Color { Color(white: dark ? 0.88 : 0.955) }
    /// The paper is light in both appearances, so its inner edge is the same faint dark line in both.
    var hairline: Color { Color.black.opacity(0.08) }
    var ink: Color { Color(white: 0.14) }
    /// The secondary label colour, on paper.
    var faintInk: Color { Color(white: 0.42) }
    var steel: Color { Color(red: 0.62, green: 0.65, blue: 0.69) }
    /// Contact shadow and cast shadow: 0 1 2 at 18%, and 0 10 24 at 22% (deeper in dark mode).
    var contact: Double { dark ? 0.35 : 0.18 }
    var cast: Double { dark ? 0.45 : 0.22 }
}

/// One print's stand-in among the line's controls. The picture, pegs and shadows are drawn by the stage's layers;
/// this sits exactly over the print at rest, clear, and takes the click (copy: a white flash, "Copied", and the
/// line tucks away), the double-click (Preview), the drag (the image goes with it) and the hover, which lifts the
/// print and shows one caption pill under it: when, from where, how big. The OCR chips, the ⌘ number and the
/// keyboard focus ring show on it too.
struct PrintProxy: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var state: ClotheslineState
    let place: PrintPlace

    private var capture: Capture { place.capture }
    private var focused: Bool { state.focusedID == capture.id }
    private var hovered: Bool { state.hoveredID == capture.id }
    private var lifted: Bool { state.isLifted(capture.id) }
    private var copied: Bool { state.copiedID == capture.id }
    private var fresh: Bool { state.unseen.contains(capture.id) }
    private var size: CGSize { place.size }
    private var chips: [String] { Array(Identifiers.find(in: capture.ocrText).prefix(2)) }
    private var sizeText: String { "\(capture.width) × \(capture.height)" }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PrintMetrics.cornerRadius, style: .continuous)
        ZStack(alignment: .topLeading) {
            // Copy: a 0.12 s white flash across the whole print.
            shape.fill(Color.white.opacity(copied && state.flashing ? 0.35 : 0))
            if focused {
                RoundedRectangle(cornerRadius: PrintMetrics.cornerRadius + 3, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
                    .padding(-3)
                    .transition(.opacity)
            }
            // ⌘N, the keys that copy it: on the hovered print, and on every print while ⌘ is held.
            if state.commandHeld || hovered, !copied, let n = state.number(of: capture.id), n <= 9 {
                NumberKey(number: n)
                    .padding(PrintMetrics.border + 4)
                    .frame(width: size.width, height: size.height, alignment: .bottomLeading)
                    .transition(.scale(scale: 0.7, anchor: .bottomLeading).combined(with: .opacity))
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("pegNumber-\(capture.id)")
            }
            if !chips.isEmpty {
                chipRow.frame(width: size.width, height: size.height, alignment: .bottomTrailing)
            }
            facts
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .overlay(alignment: .topLeading) { fasteners }
        .overlay(alignment: .top) { if copied { copiedPill.offset(y: size.height + 10) } }
        .overlay(alignment: .top) { caption.offset(y: size.height + 6) }
        .contentShape(shape)
        .onHover { state.hover(capture.id, $0) }
        // One handler, so the first click copies at once instead of waiting out the double-click interval;
        // the second click of a double-click opens Preview while "Copied" is still showing.
        .onTapGesture {
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                model.openInPreview(capture)
                model.clothesline.hide(restoreFocus: false)
            } else {
                choose()
            }
        }
        // Take it off the line: drag the print into Mail, Slack or Finder and the image goes with it.
        .onDrag {
            state.takenID = capture.id
            return NSItemProvider(contentsOf: model.engine.store.imageURL(capture)) ?? NSItemProvider()
        } preview: {
            dragPreview
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(Fmt.stamp(capture.created)), \(sizeText)\(capture.pinned ? ", pinned" : "")")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { choose() }
        .accessibilityIdentifier("peg-card-\(capture.id)")
        .scaleEffect(lifted && !LineMotion.reduced ? 1.035 : 1, anchor: .top)
        .offset(y: lifted && !LineMotion.reduced ? -6 : 0)
        .rotationEffect(.degrees(place.tilt), anchor: .top)
        .offset(x: place.x, y: place.top)
    }

    private func choose() {
        guard state.copiedID == nil else { return }
        model.copy(capture, hud: true)
        state.markCopied(capture.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + LineMotion.copiedHold) { model.hideClothesline() }
    }

    /// The print's facts for assistive apps and the tree; the eye gets them from the caption pill on hover.
    private var facts: some View {
        VStack(alignment: .leading, spacing: 0) {
            fact(Fmt.stamp(capture.created), "pegDate-\(capture.id)")
            fact(sizeText, "pegSize-\(capture.id)")
            if let app = capture.app, !app.isEmpty { fact(app, "pegSource-\(capture.id)") }
            if fresh { fact("New", "pegNewestDot") }
        }
        .allowsHitTesting(false)
    }

    private func fact(_ text: String, _ id: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 1))
            .foregroundStyle(.clear)
            .frame(width: 1, height: 1)
            .accessibilityLabel(Text(verbatim: text))
            .accessibilityIdentifier(id)
    }

    /// Where the pegs (or the clip) bite, for the tree: the jaws in front of the rope and the backs behind it, as the
    /// line has always reported them.
    private var fasteners: some View {
        let pinned = capture.pinned
        return ZStack(alignment: .topLeading) {
            pegSpots(pinned ? "peg-clip-\(capture.id)" : "peg-\(capture.id)")
            pegSpots(pinned ? "peg-clip-back-\(capture.id)" : "peg-back-\(capture.id)")
        }
        .allowsHitTesting(false)
    }

    private func pegSpots(_ id: String) -> some View {
        let pinned = capture.pinned
        let size = pinned ? SteelClip.size : WoodPeg.size
        let ropeY = pinned ? SteelClip.ropeY : WoodPeg.ropeY
        return ZStack(alignment: .topLeading) {
            ForEach(Array(place.pegs.enumerated()), id: \.offset) { _, peg in
                Color.clear
                    .frame(width: size.width, height: size.height)
                    .offset(x: peg.x - size.width / 2, y: -peg.ropeY - ropeY)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pinned ? "Pinned" : capture.app.map { "Peg, \($0)" } ?? "Peg")
        .accessibilityIdentifier(id)
    }

    /// One 11 pt pill 6 pt under the print, on hover only: "4 min ago · Safari · 1440 × 900".
    private var caption: some View {
        HStack(spacing: 5) {
            Text(PrintTime.relative(capture.created))
            if let app = capture.app, !app.isEmpty {
                Circle().fill(PegPaint.accent(for: app)).frame(width: 5, height: 5)
                Text(app).truncationMode(.tail)
            }
            Text(verbatim: sizeText)
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(ChipFill())
        .fixedSize()
        .opacity(hovered && !copied ? 1 : 0)
        .offset(y: hovered ? 0 : -4)
        .animation(.easeOut(duration: 0.14), value: hovered)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var dragPreview: some View {
        let image = PrintImages.cached(capture, store: model.engine.store)
        return Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Color.gray.opacity(0.3)
            }
        }
        .frame(width: size.width * 0.6, height: size.height * 0.6)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// Text worth copying on its own: ticket ids, links, error codes. At most two, in the bottom of the picture, only
    /// while the pointer is on the print, so at rest nothing covers the screenshot.
    private var chipRow: some View {
        let on = hovered && state.copiedID == nil
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { ForEach(Array(chips.enumerated()), id: \.offset) { i, t in chip(t, i) } }
            HStack(spacing: 4) { if let first = chips.first { chip(first, 0) } }
        }
        .frame(maxWidth: size.width - 64, alignment: .trailing)
        .padding(.trailing, PrintMetrics.border + 4)
        .padding(.bottom, PrintMetrics.border + 4)
        .opacity(on ? 1 : 0)
        .offset(y: on ? 0 : 3)
        .allowsHitTesting(on)
        .animation(.easeOut(duration: 0.14), value: on)
    }

    private func chip(_ text: String, _ index: Int) -> some View {
        Button {
            model.engine.copyText(text)
            model.showToast("Copied “\(OCRChip.label(text))”", hud: true)
            model.hideClothesline()
        } label: {
            Text(OCRChip.label(text))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 7)
                .frame(height: 18)
                .contentShape(Capsule())
        }
        .buttonStyle(ChipPress())
        .help("Copy \(text)")
        .accessibilityLabel("Copy \(text)")
        .accessibilityIdentifier("peg-chip-\(capture.id)-\(index)")
    }

    /// "Copied", just under the print it was taken from: SF 11 semibold on a dark painted capsule.
    private var copiedPill: some View {
        Label("Copied", systemImage: "checkmark")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(HUDFill())
            .transition(.scale(scale: 0.8, anchor: .top).combined(with: .opacity))
            .accessibilityIdentifier("pegCopied-\(capture.id)")
    }
}

/// "⌘1": the keys that copy a print, an 18 pt key cap in its bottom-left corner on hover and while ⌘ is held, like
/// tab numbers in Safari.
struct NumberKey: View {
    let number: Int

    var body: some View {
        HStack(spacing: 1) {
            Text("⌘").font(.system(size: 10, weight: .medium))
            Text("\(number)").font(.system(size: 11, weight: .bold).monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .frame(minWidth: 18, minHeight: 18, maxHeight: 18)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.black.opacity(0.78)))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
        .accessibilityElement()
        .accessibilityLabel("Command \(number) copies")
    }
}

/// An OCR chip on a print: a dark capsule at 55%, painted rather than blurred so window capture shows it.
private struct ChipPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Capsule()
                    .fill(Color.black.opacity(configuration.isPressed ? 0.72 : 0.55))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

/// "Just now", "4 min ago", "3 h ago", "Yesterday", then a weekday or a short date.
enum PrintTime {
    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE")
        return f
    }()

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f
    }()

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(date)
        if s < 60 { return "Just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if Calendar.current.isDateInToday(date) { return "\(Int(s / 3600)) h ago" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        if s < 6 * 86400 { return weekday.string(from: date) }
        return day.string(from: date)
    }
}

/// Prints drawn from the full image at the size they hang, downsampled by ImageIO, so text stays crisp. The whole
/// capture, always: a print is never cropped.
enum PrintImages {
    private static let cache = NSCache<NSString, NSImage>()

    private static func key(_ url: URL, _ maxPixel: Int) -> NSString { "\(url.path)#\(maxPixel)" as NSString }

    /// Decodes made so far, for the open-path trace: opening the line should add none.
    private static let counter = NSLock()
    private static var decodes = 0
    static var decodeCount: Int { counter.lock(); defer { counter.unlock() }; return decodes }

    static func cached(_ c: Capture, store: Store) -> NSImage? {
        sharp(c, store: store) ?? Images.cached(store.thumbURL(c))
    }

    /// The copy drawn at the size the print hangs, if it is decoded already.
    static func sharp(_ c: Capture, store: Store) -> NSImage? {
        cache.object(forKey: key(store.imageURL(c), PrintMetrics.sharpPixels(c)))
    }

    static func load(_ c: Capture, store: Store) async -> NSImage? {
        await load(store.imageURL(c), maxPixel: PrintMetrics.sharpPixels(c))
    }

    /// A sharp copy at a given pixel size.
    static func cached(_ url: URL, maxPixel: Int) -> NSImage? {
        cache.object(forKey: key(url, maxPixel))
    }

    static func load(_ url: URL, maxPixel: Int) async -> NSImage? {
        let k = key(url, maxPixel)
        if let hit = cache.object(forKey: k) { return hit }
        let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let cg = decode(url, maxPixel: maxPixel) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if let image { cache.setObject(image, forKey: k) }
        return image
    }

    private static func decode(_ url: URL, maxPixel: Int) -> CGImage? {
        counter.lock()
        decodes += 1
        counter.unlock()
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixel, 64),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }
}

/// How an OCR chip reads: links shortened to host and path, codes as they are.
enum OCRChip {
    static func label(_ text: String) -> String {
        var t = text
        for prefix in ["https://", "http://", "www."] where t.lowercased().hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count))
        }
        if t.hasSuffix("/") { t.removeLast() }
        return t.count > 22 ? String(t.prefix(21)) + "…" : t
    }

    static func symbol(_ text: String) -> String {
        if text.contains(".") || text.contains("/") { return "link" }
        if text.allSatisfy(\.isNumber) { return "exclamationmark.circle" }
        return "number"
    }

    /// Links blue, error codes red, ticket ids ink. The peek's chips use it; the line's stay neutral.
    static func tint(_ text: String) -> Color {
        switch symbol(text) {
        case "link": return Color(red: 0.12, green: 0.42, blue: 0.86)
        case "number": return Color(white: 0.35)
        default: return Color(red: 0.85, green: 0.24, blue: 0.2)
        }
    }
}
