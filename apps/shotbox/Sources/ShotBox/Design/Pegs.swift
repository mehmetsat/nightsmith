import AppKit
import SwiftUI

/// Peg colour carries the source app: each peg wears a cap in the app's colour. Known apps use their brand colour;
/// others take the strongest hue of their icon. No app at all, a darker wood.
enum PegPaint {
    /// Bare beech, #C9A574.
    static let wood = Color(red: 0xC9 / 255, green: 0xA5 / 255, blue: 0x74 / 255)
    private static let darkWood = Color(red: 0.55, green: 0.40, blue: 0.24)

    private static let accents: [String: (Double, Double, Double)] = [
        "safari": (0.04, 0.48, 1.0), "figma": (0.64, 0.33, 1.0), "slack": (0.55, 0.18, 0.52),
        "xcode": (0.11, 0.56, 0.98), "google chrome": (0.86, 0.27, 0.22), "chrome": (0.86, 0.27, 0.22),
        "firefox": (1.0, 0.45, 0.1), "arc": (0.93, 0.33, 0.43), "mail": (0.15, 0.55, 1.0),
        "messages": (0.2, 0.78, 0.3), "notes": (0.98, 0.78, 0.12), "terminal": (0.13, 0.13, 0.14),
        "finder": (0.2, 0.6, 1.0), "preview": (0.33, 0.6, 0.86), "code": (0.0, 0.47, 0.83),
        "visual studio code": (0.0, 0.47, 0.83), "notion": (0.18, 0.18, 0.18), "linear": (0.37, 0.42, 0.86),
        "discord": (0.35, 0.4, 0.95), "zoom": (0.18, 0.55, 1.0), "music": (0.98, 0.24, 0.35),
        "keynote": (0.2, 0.55, 0.95), "pages": (1.0, 0.6, 0.1), "numbers": (0.2, 0.75, 0.3),
        "shotbox": (0.45, 0.5, 0.58), "system settings": (0.5, 0.52, 0.56),
    ]

    /// Icons are sampled once per app: the line asks on every frame of a drop.
    private static var cache: [String: Color] = [:]

    /// The app's colour: a peg's cap, the dot in a caption.
    static func accent(for app: String?) -> Color {
        guard let app, !app.isEmpty else { return darkWood }
        if let hit = cache[app] { return hit }
        let color: Color
        if let a = accents[app.lowercased()] {
            color = Color(red: a.0, green: a.1, blue: a.2)
        } else {
            color = icon(for: app).flatMap(dominant).map(Color.init(nsColor:)) ?? darkWood
        }
        cache[app] = color
        return color
    }

    private static func icon(for app: String) -> NSImage? {
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == app }), let icon = running.icon {
            return icon
        }
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                    "/System/Library/CoreServices", NSHomeDirectory() + "/Applications"]
        for dir in dirs {
            let path = "\(dir)/\(app).app"
            if FileManager.default.fileExists(atPath: path) { return NSWorkspace.shared.icon(forFile: path) }
        }
        return nil
    }

    /// The most common strong hue in the icon, averaged.
    private static func dominant(_ icon: NSImage) -> NSColor? {
        let side = 24
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        var bins = [(w: CGFloat, r: CGFloat, g: CGFloat, b: CGFloat)](repeating: (0, 0, 0, 0), count: 12)
        for y in 0..<side {
            for x in 0..<side {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.6 else { continue }
                let s = c.saturationComponent, v = c.brightnessComponent
                guard s >= 0.18, v >= 0.15 else { continue }
                let w = s * v
                let i = min(Int(c.hueComponent * 12), 11)
                bins[i] = (bins[i].w + w, bins[i].r + c.redComponent * w, bins[i].g + c.greenComponent * w, bins[i].b + c.blueComponent * w)
            }
        }
        let best = bins.max { $0.w < $1.w }!
        guard best.w > 4 else { return nil }
        return NSColor(srgbRed: best.r / best.w, green: best.g / best.w, blue: best.b / best.w, alpha: 1)
    }
}

/// What makes one peg not the same as the next. Each print's pegs are cut from one piece of beech (#C9A27A), up to
/// 8 % lighter or darker than the next print's; each peg has its own grain and is clipped on at its own angle, up to
/// 6° either way, a few points off the even spot. All seeded by the capture's id, so a print wears the same pegs on
/// every open.
struct PegLook: Hashable {
    /// Lightness step of the wood, -2…2, 4 % apart.
    let tone: Int
    let grain: Int
    let angle: Double
    let nudge: Double

    static let beech = (0xC9 / 255.0, 0xA2 / 255.0, 0x7A / 255.0)

    /// A look with only its wood and grain, as the key for its drawn image.
    init(tone: Int, grain: Int) {
        self.tone = tone
        self.grain = grain
        angle = 0
        nudge = 0
    }

    init(capture id: Int64, peg k: Int) {
        let wood = Self.mix(UInt64(bitPattern: id))
        let own = Self.mix(UInt64(bitPattern: id) &* 31 &+ UInt64(k) &+ 1)
        tone = Int(wood % 5) - 2
        grain = Int(own % 3)
        angle = (Double((own >> 8) % 1000) / 999 - 0.5) * 12
        nudge = (Double((own >> 20) % 1000) / 999 - 0.5) * 10
    }

    init(seed: Int) {
        self.init(capture: Int64(seed), peg: 0)
    }

    private static func mix(_ seed: UInt64) -> UInt64 {
        var x = seed &+ 0x9E37_79B9_7F4A_7C15
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        return x ^ (x >> 31)
    }

    /// Light, mid and dark of the wood, for its rounded face.
    var shades: (light: Color, mid: Color, dark: Color) {
        let l = 1 + 0.04 * Double(tone)
        let w = (min(Self.beech.0 * l, 1), min(Self.beech.1 * l, 1), min(Self.beech.2 * l, 1))
        return (Color(red: w.0 + (1 - w.0) * 0.32, green: w.1 + (1 - w.1) * 0.32, blue: w.2 + (1 - w.2) * 0.32),
                Color(red: w.0, green: w.1, blue: w.2),
                Color(red: w.0 * 0.78, green: w.1 * 0.78, blue: w.2 * 0.78))
    }
}

/// A wooden clothes peg, 7 × 18 pt, seen from the front: rounded wood lit from the left, with a 1 pt highlight down
/// that side, faint grain, a steel spring just under the rope, a darker hinge line where the legs pivot and the split
/// between the legs below it.
struct WoodPeg: View {
    static let size = CGSize(width: 7, height: 18)
    /// Where the rope runs through the jaws, from the peg's top.
    static let ropeY: CGFloat = 4
    var look: PegLook
    /// Drawn at its clipped-on angle. The line's layers turn the peg themselves, so they ask for it square.
    var tilted = true

    init(seed: Int, tilted: Bool = true) {
        look = PegLook(seed: seed)
        self.tilted = tilted
    }

    init(look: PegLook, tilted: Bool) {
        self.look = look
        self.tilted = tilted
    }

    var body: some View {
        let w = Self.size.width, h = Self.size.height
        let shades = look.shades
        let grain = look.grain
        let hinge: CGFloat = 9.5
        ZStack(alignment: .topLeading) {
            let body = RoundedRectangle(cornerRadius: 2, style: .continuous)
            body.fill(LinearGradient(colors: [shades.light, shades.mid, shades.dark],
                                     startPoint: .leading, endPoint: .trailing))
            // Grain: two faint streaks, placed by the look, so a row of pegs never looks stamped.
            Canvas { ctx, size in
                for k in 0..<2 {
                    let x = 1.8 + CGFloat((grain * 2 + k * 3) % 4) * 1.1
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: 2))
                    p.addQuadCurve(to: CGPoint(x: x + 0.3, y: size.height - 1.5),
                                   control: CGPoint(x: x - 0.7 + CGFloat(grain) * 0.4, y: size.height / 2))
                    ctx.stroke(p, with: .color(Color(red: 0.4, green: 0.26, blue: 0.12).opacity(0.2)), lineWidth: 0.4)
                }
            }
            // The 1 pt highlight down the lit side.
            Rectangle()
                .fill(Color.white.opacity(0.55))
                .frame(width: 1, height: h - 3)
                .offset(x: 0.9, y: 1.5)
            // The hinge, where the legs pivot: a darker line across the peg.
            Rectangle()
                .fill(Color(red: 0.3, green: 0.19, blue: 0.08).opacity(0.55))
                .frame(width: w - 1, height: 0.7)
                .offset(x: 0.5, y: hinge)
            // The split between the legs below it.
            Rectangle()
                .fill(Color(red: 0.3, green: 0.19, blue: 0.08).opacity(0.35))
                .frame(width: 0.6, height: h - hinge - 1.5)
                .offset(x: w / 2 - 0.3, y: hinge + 0.7)
            // The steel spring, just below the rope.
            Capsule()
                .fill(LinearGradient(colors: [Color(white: 0.95), Color(white: 0.5)], startPoint: .top, endPoint: .bottom))
                .overlay(Capsule().strokeBorder(Color.black.opacity(0.3), lineWidth: 0.3))
                .frame(width: w + 1, height: 1.6)
                .offset(x: -0.5, y: Self.ropeY + 2.2)
            body.strokeBorder(Color(red: 0.34, green: 0.22, blue: 0.1).opacity(0.5), lineWidth: 0.5)
        }
        .frame(width: w, height: h)
        .rotationEffect(.degrees(tilted ? look.angle : 0), anchor: UnitPoint(x: 0.5, y: Self.ropeY / h))
    }
}

/// A pinned print hangs from one metal binder clip in the accent colour, 12 × 24 pt, instead of wooden pegs: office
/// hardware among the wood, so a pin reads at a glance. Its print hangs square and never drops off the line.
struct SteelClip: View {
    static let size = CGSize(width: 12, height: 24)
    /// Where the rope runs through the wire loop, from the clip's top.
    static let ropeY: CGFloat = 5
    var body: some View {
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        let light = Color(nsColor: accent.blended(withFraction: 0.35, of: .white) ?? accent)
        let deep = Color(nsColor: accent.blended(withFraction: 0.3, of: .black) ?? accent)
        ZStack(alignment: .top) {
            WireLoop()
                .stroke(LinearGradient(colors: [Color(white: 0.97), Color(white: 0.55), Color(white: 0.88)],
                                       startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                .frame(width: 9, height: 11)
            ClipBody()
                .fill(LinearGradient(colors: [light, Color(nsColor: accent), deep], startPoint: .top, endPoint: .bottom))
                .overlay {
                    // Brushed: fine horizontal strokes.
                    Canvas { ctx, size in
                        var p = Path()
                        var y: CGFloat = 1
                        while y < size.height {
                            p.move(to: CGPoint(x: 0, y: y))
                            p.addLine(to: CGPoint(x: size.width, y: y))
                            y += 1.1
                        }
                        ctx.stroke(p, with: .color(.white.opacity(0.16)), lineWidth: 0.35)
                    }
                    .clipShape(ClipBody())
                }
                .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.7)).frame(height: 0.6).padding(.horizontal, 1.6) }
                .overlay(ClipBody().stroke(Color.black.opacity(0.35), lineWidth: 0.5))
                .frame(width: Self.size.width, height: 15)
                .offset(y: 9)
            }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}

/// The pegs and the clip as images, drawn once from the SwiftUI artwork above at 3× and handed to the line's layers,
/// which turn them and cast their contact shadows. Nothing here is drawn while the line is moving.
@MainActor
enum PegArt {
    /// Clear room around the artwork in the image, so nothing is clipped at its edges.
    static let pad: CGFloat = 2
    private static var pegs: [PegLook: CGImage] = [:]
    private static var clipImage: CGImage?

    static func peg(_ look: PegLook) -> CGImage? {
        let key = PegLook(tone: look.tone, grain: look.grain)
        if let hit = pegs[key] { return hit }
        let image = render(WoodPeg(look: key, tilted: false).frame(width: WoodPeg.size.width, height: WoodPeg.size.height))
        pegs[key] = image
        return image
    }

    static var clip: CGImage? {
        if let clipImage { return clipImage }
        clipImage = render(SteelClip())
        return clipImage
    }

    private static func render(_ view: some View) -> CGImage? {
        let r = ImageRenderer(content: view.padding(pad))
        r.scale = 3
        return r.cgImage
    }
}

/// The clip's jaw: a little wider at the bottom, where it bites the paper.
private struct ClipBody: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + 1.6, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - 1.6, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - 1.2))
        p.addQuadCurve(to: CGPoint(x: r.maxX - 1.2, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + 1.2, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - 1.2), control: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// The folded-back wire handles; the rope runs through their loop.
private struct WireLoop: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + 0.8, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + 1.2, y: r.minY + 3))
        p.addQuadCurve(to: CGPoint(x: r.maxX - 1.2, y: r.minY + 3), control: CGPoint(x: r.midX, y: r.minY - 1.5))
        p.addLine(to: CGPoint(x: r.maxX - 0.8, y: r.maxY))
        return p
    }
}

extension Color {
    /// Mixes towards another colour; `Color.mix` needs macOS 15.
    func blend(_ other: NSColor, _ fraction: CGFloat) -> Color {
        let base = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        return Color(nsColor: base.blended(withFraction: fraction, of: other) ?? base)
    }
}
