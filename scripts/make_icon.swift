// make_icon.swift <out.png> [style]: draws the 1024×1024 ShotBox icon.
// A line under a dark sky with pegged prints. style: midnight (default), paper, graphite.
import AppKit

let size: CGFloat = 1024
let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "icon.png"
let style = args.count > 2 ? args[2] : "midnight"

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a).cgColor }
func gradient(_ colors: [CGColor], _ locs: [CGFloat]? = nil) -> CGGradient {
  CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors as CFArray, locations: locs)!
}

struct Palette {
  var skyTop, skyBottom, glow, rope, ropeHi, pegLight, pegDark, paper: CGColor
  var prints: [[CGColor]]
}
let palettes: [String: Palette] = [
  "midnight": Palette(skyTop: rgb(0.13, 0.15, 0.24), skyBottom: rgb(0.03, 0.04, 0.08), glow: rgb(1.0, 0.72, 0.45, 0.30),
                      rope: rgb(0.80, 0.64, 0.40), ropeHi: rgb(1.0, 0.90, 0.70), pegLight: rgb(0.93, 0.80, 0.58), pegDark: rgb(0.62, 0.47, 0.28),
                      paper: rgb(0.98, 0.97, 0.95),
                      prints: [[rgb(0.98, 0.62, 0.42), rgb(0.86, 0.36, 0.38)], [rgb(0.36, 0.52, 0.92), rgb(0.20, 0.26, 0.58)], [rgb(0.55, 0.82, 0.70), rgb(0.20, 0.50, 0.52)]]),
  "paper": Palette(skyTop: rgb(0.99, 0.97, 0.94), skyBottom: rgb(0.90, 0.87, 0.82), glow: rgb(1, 1, 1, 0.5),
                   rope: rgb(0.16, 0.15, 0.14), ropeHi: rgb(0.40, 0.38, 0.35), pegLight: rgb(0.85, 0.70, 0.50), pegDark: rgb(0.58, 0.44, 0.30),
                   paper: rgb(1, 1, 1),
                   prints: [[rgb(0.95, 0.55, 0.40), rgb(0.80, 0.30, 0.30)], [rgb(0.17, 0.18, 0.22), rgb(0.08, 0.08, 0.10)], [rgb(0.45, 0.65, 0.90), rgb(0.25, 0.38, 0.70)]]),
  "graphite": Palette(skyTop: rgb(0.30, 0.31, 0.34), skyBottom: rgb(0.09, 0.09, 0.10), glow: rgb(1, 0.45, 0.35, 0.25),
                      rope: rgb(0.75, 0.76, 0.79), ropeHi: rgb(1, 1, 1), pegLight: rgb(0.90, 0.91, 0.93), pegDark: rgb(0.55, 0.56, 0.60),
                      paper: rgb(0.97, 0.97, 0.98),
                      prints: [[rgb(0.98, 0.45, 0.35), rgb(0.85, 0.22, 0.30)], [rgb(0.98, 0.45, 0.35), rgb(0.85, 0.22, 0.30)], [rgb(0.98, 0.45, 0.35), rgb(0.85, 0.22, 0.30)]]),
]
let pal = palettes[style] ?? palettes["midnight"]!

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824 pt rounded square, continuous-looking corners.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35))
ctx.addPath(tilePath); ctx.setFillColor(pal.skyBottom); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
ctx.drawLinearGradient(gradient([pal.skyTop, pal.skyBottom]), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// A soft light source behind the line.
ctx.drawRadialGradient(gradient([pal.glow, rgb(0, 0, 0, 0)]), startCenter: CGPoint(x: 512, y: 640), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 640), endRadius: 470, options: [])

// The line: a gentle catenary, edge to edge.
let left = CGPoint(x: 60, y: 690), right = CGPoint(x: 964, y: 690), sagY: CGFloat = 610
func lineY(_ x: CGFloat) -> CGFloat {
  let t = (x - left.x) / (right.x - left.x)
  return left.y - (left.y - sagY) * 4 * t * (1 - t)
}
func slope(_ x: CGFloat) -> CGFloat { atan((lineY(x + 1) - lineY(x - 1)) / 2) }
let rope = CGMutablePath()
rope.move(to: left)
for x in stride(from: left.x, through: right.x, by: 2) { rope.addLine(to: CGPoint(x: x, y: lineY(x))) }
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 8, color: rgb(0, 0, 0, 0.35))
ctx.addPath(rope); ctx.setLineWidth(7); ctx.setLineCap(.round); ctx.setStrokeColor(pal.rope); ctx.strokePath()
ctx.restoreGState()
ctx.addPath(rope.copy(using: [CGAffineTransform(translationX: 0, y: 1.5)].withUnsafeBufferPointer { $0.baseAddress })!)
ctx.setLineWidth(2); ctx.setStrokeColor(pal.ropeHi.copy(alpha: 0.6)!); ctx.strokePath()

// Prints: back two smaller, the centre one large and in front.
struct Print { var x, w, h, tilt: CGFloat; var fill: [CGColor]; var front: Bool }
let prints = [
  Print(x: 150, w: 270, h: 216, tilt: 5, fill: pal.prints[0], front: false),
  Print(x: 874, w: 270, h: 216, tilt: -5, fill: pal.prints[2], front: false),
  Print(x: 512, w: 450, h: 356, tilt: -1.5, fill: pal.prints[1], front: true),
]

func drawPeg(at x: CGFloat, angle: CGFloat) {
  ctx.saveGState()
  ctx.translateBy(x: x, y: 0)
  ctx.rotate(by: angle)
  let body = CGRect(x: -12, y: -46, width: 24, height: 76)
  ctx.setShadow(offset: CGSize(width: 0, height: -5), blur: 8, color: rgb(0, 0, 0, 0.35))
  ctx.addPath(CGPath(roundedRect: body, cornerWidth: 7, cornerHeight: 7, transform: nil))
  ctx.setFillColor(pal.pegDark); ctx.fillPath()
  ctx.setShadow(offset: .zero, blur: 0, color: nil)
  ctx.saveGState()
  ctx.addPath(CGPath(roundedRect: body, cornerWidth: 7, cornerHeight: 7, transform: nil)); ctx.clip()
  ctx.drawLinearGradient(gradient([pal.pegLight, pal.pegDark]), start: CGPoint(x: -12, y: 0), end: CGPoint(x: 14, y: 0), options: [])
  ctx.restoreGState()
  // The split between the two halves and the spring.
  ctx.setFillColor(rgb(0, 0, 0, 0.28)); ctx.fill(CGRect(x: -0.75, y: -46, width: 1.5, height: 76))
  ctx.setFillColor(rgb(0.85, 0.86, 0.88)); ctx.fill(CGRect(x: -13, y: -4, width: 26, height: 5))
  ctx.setFillColor(rgb(1, 1, 1, 0.7)); ctx.fill(CGRect(x: -13, y: 0, width: 26, height: 1.2))
  ctx.restoreGState()
}

for p in prints {
  let top = lineY(p.x)
  ctx.saveGState()
  ctx.translateBy(x: p.x, y: top)
  ctx.rotate(by: p.tilt * .pi / 180)
  let frame = CGRect(x: -p.w / 2, y: -p.h + 14, width: p.w, height: p.h)
  // Shadow: a tight contact one and a long soft one.
  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: -26), blur: 44, color: rgb(0, 0, 0, p.front ? 0.55 : 0.40))
  ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 10, cornerHeight: 10, transform: nil)); ctx.setFillColor(pal.paper); ctx.fillPath()
  ctx.restoreGState()
  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 4, color: rgb(0, 0, 0, 0.25))
  ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 10, cornerHeight: 10, transform: nil)); ctx.setFillColor(pal.paper); ctx.fillPath()
  ctx.restoreGState()
  // Paper sheen.
  ctx.saveGState()
  ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 10, cornerHeight: 10, transform: nil)); ctx.clip()
  ctx.drawLinearGradient(gradient([rgb(1, 1, 1, 0), rgb(0, 0, 0, 0.06)]), start: CGPoint(x: 0, y: frame.maxY), end: CGPoint(x: 0, y: frame.minY), options: [])
  ctx.restoreGState()

  // The picture inside the border: a gradient "screenshot" with a window bar and a highlight.
  let border: CGFloat = p.front ? 18 : 15
  let inner = CGRect(x: frame.minX + border, y: frame.minY + border * 2.4, width: frame.width - border * 2, height: frame.height - border * 3.4)
  let innerPath = CGPath(roundedRect: inner, cornerWidth: 5, cornerHeight: 5, transform: nil)
  ctx.saveGState()
  ctx.addPath(innerPath); ctx.clip()
  ctx.drawLinearGradient(gradient(p.fill), start: CGPoint(x: inner.minX, y: inner.maxY), end: CGPoint(x: inner.maxX, y: inner.minY), options: [])
  // Window chrome bar.
  let bar = CGRect(x: inner.minX, y: inner.maxY - inner.height * 0.16, width: inner.width, height: inner.height * 0.16)
  ctx.setFillColor(rgb(1, 1, 1, 0.16)); ctx.fill(bar)
  for i in 0..<3 {
    let d = bar.height * 0.34
    ctx.setFillColor(rgb(1, 1, 1, 0.75))
    ctx.fillEllipse(in: CGRect(x: bar.minX + bar.height * 0.4 + CGFloat(i) * d * 1.6, y: bar.midY - d / 2, width: d, height: d))
  }
  if p.front {
    // A small landscape: sun and two hills, so the print reads as a picture at any size.
    let below = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: bar.minY - inner.minY)
    let sun = CGRect(x: below.minX + below.width * 0.62, y: below.minY + below.height * 0.50, width: below.width * 0.17, height: below.width * 0.17)
    ctx.setFillColor(rgb(1, 0.86, 0.62, 0.95)); ctx.fillEllipse(in: sun)
    func hill(_ y0: CGFloat, _ peakX: CGFloat, _ peakY: CGFloat, _ c: CGColor) {
      let h = CGMutablePath()
      h.move(to: CGPoint(x: below.minX - 20, y: below.minY + below.height * y0))
      h.addQuadCurve(to: CGPoint(x: below.maxX + 20, y: below.minY + below.height * (y0 - 0.1)),
                     control: CGPoint(x: below.minX + below.width * peakX, y: below.minY + below.height * peakY))
      h.addLine(to: CGPoint(x: below.maxX + 20, y: below.minY - 2)); h.addLine(to: CGPoint(x: below.minX - 20, y: below.minY - 2))
      ctx.addPath(h); ctx.setFillColor(c); ctx.fillPath()
    }
    hill(0.30, 0.30, 0.95, rgb(1, 1, 1, 0.22))
    hill(0.10, 0.75, 0.60, rgb(0, 0, 0, 0.22))
  }
  // Glass highlight across the top.
  ctx.drawLinearGradient(gradient([rgb(1, 1, 1, 0.22), rgb(1, 1, 1, 0)]), start: CGPoint(x: 0, y: inner.maxY), end: CGPoint(x: 0, y: inner.midY), options: [])
  ctx.restoreGState()
  ctx.addPath(innerPath); ctx.setStrokeColor(rgb(0, 0, 0, 0.08)); ctx.setLineWidth(1.5); ctx.strokePath()
  if !p.front {
    // Back prints sit in the shade, so the front one leads.
    ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 10, cornerHeight: 10, transform: nil))
    ctx.setFillColor(rgb(0, 0, 0, 0.09)); ctx.fillPath()
  }
  ctx.restoreGState()

  // Pegs sit on the line, following its slope.
  for dx in [-p.w / 2 + 44, p.w / 2 - 44] {
    let px = p.x + dx
    ctx.saveGState()
    ctx.translateBy(x: 0, y: lineY(px))
    drawPeg(at: px, angle: slope(px) + p.tilt * .pi / 360)
    ctx.restoreGState()
  }
}

// Bevel: a thin light edge at the top of the tile, a dark one at the bottom.
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
ctx.addPath(tilePath)
ctx.setLineWidth(5)
ctx.replacePathWithStrokedPath(); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(1, 1, 1, 0.35), rgb(1, 1, 1, 0.02), rgb(0, 0, 0, 0.25)], [0, 0.5, 1]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print(out)
