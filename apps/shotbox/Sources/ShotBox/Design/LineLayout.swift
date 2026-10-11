import SwiftUI

/// Sizes of a print. A print is the screenshot on a sheet of photo paper: a 5 pt paper border, a 0.5 pt hairline and
/// 6 pt corners round the picture, never cropped. Prints scale with the screen they hang on, so a real screenshot is
/// readable on an ultrawide as on a laptop: a 16:10 capture hangs 150 pt tall on a 1440 pt screen and up to 230 pt on
/// a 3440 pt one. Very wide captures are capped at 1.9 times that and come out shorter; very tall ones keep a
/// narrow width and sit letterboxed on the paper.
enum PrintMetrics {
    /// A print's height at rest, paper included, for the screen the line is fitted to.
    private(set) static var restHeight: CGFloat = 170
    static let border: CGFloat = 5
    static let cornerRadius: CGFloat = 6
    /// The picture's own corners, inside the paper.
    static let pictureRadius: CGFloat = 2
    /// How far below the rope a print's top edge hangs. The 18 pt pegs reach 14 pt below the rope, so at 10 pt each
    /// one bites 4 pt of the paper border, clear of the picture.
    static let grip: CGFloat = 10

    /// 6.6 % of the screen's width, between 150 and 230 pt.
    static func fit(screenWidth: CGFloat) {
        restHeight = min(max((screenWidth * 0.066).rounded(), 150), 230)
    }

    static var maxWidth: CGFloat { (restHeight * 1.9).rounded() }
    static var minWidth: CGFloat { (restHeight * 0.62).rounded() }
    /// A 16:10 screenshot, for working out how many fit across the screen.
    static var typicalWidth: CGFloat { ((restHeight - 2 * border) * 1.6 + 2 * border).rounded() }
    /// Prints at least this wide hang from two pegs.
    static var twoPegWidth: CGFloat { restHeight * 0.8 }
    /// The gap between neighbours on the rope.
    static var gap: CGFloat { max(28, (restHeight * 0.16).rounded()) }

    /// The print, paper included.
    static func size(_ c: Capture) -> CGSize {
        let p = picture(c)
        return CGSize(width: max(p.width + 2 * border, minWidth), height: p.height + 2 * border)
    }

    /// The picture inside the paper border, at the capture's own aspect.
    static func picture(_ c: Capture) -> CGSize {
        let h = restHeight - 2 * border
        guard c.width > 0, c.height > 0 else { return CGSize(width: (h * 1.6).rounded(), height: h) }
        let aspect = CGFloat(c.width) / CGFloat(c.height)
        let w = min(h * aspect, maxWidth - 2 * border).rounded()
        return CGSize(width: w, height: (w / aspect).rounded())
    }

    static func width(_ c: Capture) -> CGFloat { size(c).width }
    static func height(_ c: Capture) -> CGFloat { size(c).height }

    /// Pixel size the picture is decoded at: twice its longest side, so text stays sharp on a Retina screen.
    static func sharpPixels(_ c: Capture) -> Int {
        let p = picture(c)
        return Int(max(p.width, p.height) * 2)
    }

    /// Where along its width a print is gripped. Pinned prints hang from one clip at the middle.
    static func pegSpots(_ c: Capture) -> [CGFloat] {
        let w = width(c)
        guard !c.pinned, w >= twoPegWidth else { return [w / 2] }
        // Pegged by hand: each a few points off the even spot, never the same twice along the line.
        let a = CGFloat(PegLook(capture: c.id, peg: 0).nudge)
        let b = CGFloat(PegLook(capture: c.id, peg: 1).nudge)
        return [(w * 0.16 + a).rounded(), (w * 0.84 + b).rounded()]
    }

    /// The size of a capture's resting tilt, the same every time it hangs: 0.8° to 2.2°. Pinned prints hang square.
    static func tiltMagnitude(_ c: Capture) -> Double {
        guard !c.pinned else { return 0 }
        return 0.8 + 1.4 * Double(hash(c) % 1000) / 999
    }

    /// A small signed tilt, for places with no rope to follow (the basket).
    static func naturalTilt(_ c: Capture) -> Double {
        (hash(c) >> 11) & 1 == 0 ? tiltMagnitude(c) : -tiltMagnitude(c)
    }

    private static func hash(_ c: Capture) -> UInt64 {
        var x = UInt64(bitPattern: c.id) &+ 0x9E37_79B9
        x = (x ^ (x >> 16)) &* 0x45D9_F3B
        x = (x ^ (x >> 16)) &* 0x45D9_F3B
        return x ^ (x >> 16)
    }
}

/// The rope: anchored 10 pt below the menubar at both screen edges, hanging along a catenary whose middle sits 3 % of
/// the screen's width lower (26 to 60 pt), with a 3–4 pt extra dip under each print where its weight pulls. Heights
/// are from the window's top edge, which is the menubar's bottom edge.
struct RopeCurve {
    static let anchor: CGFloat = 10

    static func restSag(width: CGFloat) -> CGFloat { min(max((width * 0.03).rounded(), 26), 60) }

    struct Dip {
        let x: CGFloat
        let spread: CGFloat
        let depth: CGFloat
    }

    let width: CGFloat
    var top: CGFloat = RopeCurve.anchor
    var sag: CGFloat
    var dips: [Dip] = []

    init(width: CGFloat, top: CGFloat = RopeCurve.anchor, sag: CGFloat? = nil, dips: [Dip] = []) {
        self.width = width
        self.top = top
        self.sag = sag ?? Self.restSag(width: width)
        self.dips = dips
    }

    /// Height of the rope at x.
    func y(_ x: CGFloat) -> CGFloat {
        let u = (x - width / 2) / max(width / 2, 1)
        let k: CGFloat = 1.6
        var d = sag * (cosh(k) - cosh(k * u)) / (cosh(k) - 1)
        for dip in dips {
            let t = (x - dip.x) / dip.spread
            d += dip.depth * exp(-t * t)
        }
        return top + d
    }

    /// The rope sampled every few points, past both screen edges. Two curves of the same width always give the same
    /// number of points, so Core Animation can spring one path into the other.
    func points() -> [CGPoint] {
        let n = max(Int((width + 8) / 6), 8)
        return (0...n).map { i in
            let x = -4 + (width + 8) * CGFloat(i) / CGFloat(n)
            return CGPoint(x: x, y: y(x))
        }
    }

    /// The rope with no weight on it, 2 pt of sag: where it starts before the prints land, and where it goes when the
    /// line is put away.
    static func taut(width: CGFloat) -> RopeCurve { RopeCurve(width: width, sag: 2) }

    /// The deepest the rope and its prints reach on a screen this wide, plus room under them for the hover caption
    /// and the search: the height of the line's part of the window.
    static func lineHeight(width: CGFloat) -> CGFloat {
        (anchor + restSag(width: width) + 4 + PrintMetrics.grip + PrintMetrics.restHeight + 10 + 76).rounded()
    }
}
/// One peg (or the clip) of a print, in the print's own coordinates.
struct PegPlace {
    /// From the print's left edge.
    let x: CGFloat
    /// How far the rope point sits above the print's top edge: about `PrintMetrics.grip`, slid a little so the peg is
    /// on the rope even though the print is tilted.
    let ropeY: CGFloat
    let look: PegLook
}

/// Where and how one print hangs, at rest.
struct PrintPlace: Identifiable {
    let capture: Capture
    let index: Int
    /// Left edge.
    let x: CGFloat
    /// The top edge's height at the print's centre, from the window's top.
    let top: CGFloat
    let size: CGSize
    /// Degrees, clockwise.
    let tilt: Double
    /// The angle the print is released at on the drop: 5° the other way, so it swings through to rest.
    let release: Double
    let pegs: [PegPlace]

    var id: Int64 { capture.id }
    var centre: CGFloat { x + size.width / 2 }
}

/// The whole line at rest for a set of prints on a screen of a given width: newest at the left, a gap that grows with
/// the prints apart, centred in the middle three quarters of the screen, clear of the basket at the right end of the
/// rope. Worked out once per change; the Core Animation stage draws
/// it and the SwiftUI proxies take clicks and accessibility at the same places.
struct LineLayout {
    static let margin: CGFloat = 24
    static var gap: CGFloat { PrintMetrics.gap }
    /// Room kept at the right end of the rope for the basket tag.
    static let tagReserve: CGFloat = 64
    /// Where the basket tag hangs, from the right edge.
    static let tagInset: CGFloat = 34

    /// The width prints may take along the line: the middle 76 % of the screen, where the eye already is.
    static func room(_ viewport: CGFloat) -> CGFloat { min(viewport * 0.76, viewport - 2 * margin - tagReserve) }

    static func span(_ prints: [Capture]) -> CGFloat {
        prints.map(PrintMetrics.width).reduce(0, +) + gap * CGFloat(max(prints.count - 1, 0))
    }

    let width: CGFloat
    let rope: RopeCurve
    let prints: [PrintPlace]

    static let empty = LineLayout([], width: 1440)

    init(_ captures: [Capture], width: CGFloat) {
        self.width = width
        let total = Self.span(captures)
        var x = max(Self.margin, min((width - total) / 2, width - Self.tagReserve - total))
        var lefts: [CGFloat] = []
        for c in captures {
            lefts.append(x)
            x += PrintMetrics.width(c) + Self.gap
        }
        // Each print pulls the rope down 3 to 4 pt over its own width, more for a bigger print.
        let dips = zip(captures, lefts).map { c, left -> RopeCurve.Dip in
            let s = PrintMetrics.size(c)
            let weight = min(max(s.width * s.height / (PrintMetrics.typicalWidth * PrintMetrics.restHeight), 0.5), 1.5)
            return RopeCurve.Dip(x: left + s.width / 2, spread: s.width * 0.42, depth: 2.5 + weight)
        }
        let rope = RopeCurve(width: width, dips: dips)
        self.rope = rope
        prints = captures.enumerated().map { i, c in
            let s = PrintMetrics.size(c)
            let xc = lefts[i] + s.width / 2
            // The print leans the way the rope runs between its pegs, give or take its own seeded lean, between
            // 0.8° and 2.2°, so both pegs bite. Pinned prints hang square from their clip.
            let spots = PrintMetrics.pegSpots(c)
            let a = lefts[i] + (spots.first ?? s.width / 2) - (spots.count > 1 ? 0 : 12)
            let b = lefts[i] + (spots.last ?? s.width / 2) + (spots.count > 1 ? 0 : 12)
            let chord = Double(atan2(rope.y(b) - rope.y(a), b - a)) * 180 / .pi
            let seeded = PrintMetrics.naturalTilt(c)
            let tilt: Double
            if c.pinned {
                tilt = 0
            } else if abs(chord) < 0.3 {
                tilt = seeded
            } else {
                let lean = abs(chord) + 0.4 * (PrintMetrics.tiltMagnitude(c) - 1.5)
                tilt = (chord > 0 ? 1 : -1) * min(max(lean, 0.8), 2.2)
            }
            let top = rope.y(xc) + PrintMetrics.grip
            let theta = tilt * .pi / 180
            let pegs = spots.enumerated().map { k, spot -> PegPlace in
                // Slide each peg along the paper's edge until its jaws are on the rope.
                let dx = spot - s.width / 2
                let wx = xc + dx * CGFloat(cos(theta))
                let edge = top + dx * CGFloat(sin(theta))
                let ropeY = (edge - rope.y(wx)) / CGFloat(cos(theta))
                return PegPlace(x: spot, ropeY: min(max(ropeY, PrintMetrics.grip - 4), PrintMetrics.grip + 4),
                                look: PegLook(capture: c.id, peg: k))
            }
            let release = c.pinned ? (i.isMultiple(of: 2) ? 5.0 : -5.0) : (tilt > 0 ? -5.0 : 5.0)
            return PrintPlace(capture: c, index: i, x: lefts[i], top: top, size: s, tilt: tilt,
                              release: release, pegs: pegs)
        }
    }

    /// The lowest point any print reaches at rest.
    var lowest: CGFloat {
        prints.map { p in
            let corner = p.size.width / 2 * CGFloat(abs(sin(p.tilt * .pi / 180)))
            return p.top + p.size.height + corner
        }.max() ?? 0
    }

    func place(_ id: Int64) -> PrintPlace? { prints.first { $0.id == id } }
}
