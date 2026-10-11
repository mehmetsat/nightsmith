// make_icon.swift <out.png>: draws a 1024×1024 app icon: a sagging line with three pegged prints.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: rounded square inset ~10%.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: NSColor.black.withAlphaComponent(0.28).cgColor)
ctx.addPath(tilePath); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
let sky = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
  NSColor(srgbRed: 0.98, green: 0.88, blue: 0.76, alpha: 1).cgColor,
  NSColor(srgbRed: 0.93, green: 0.62, blue: 0.55, alpha: 1).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sky, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// The line: a catenary-like sag from edge to edge.
let left = CGPoint(x: 90, y: 700), right = CGPoint(x: 934, y: 700), sagY: CGFloat = 590
func lineY(_ x: CGFloat) -> CGFloat {
  let t = (x - left.x) / (right.x - left.x)
  return left.y - (left.y - sagY) * 4 * t * (1 - t)
}
let rope = CGMutablePath()
rope.move(to: left)
for x in stride(from: left.x, through: right.x, by: 4) { rope.addLine(to: CGPoint(x: x, y: lineY(x))) }
ctx.addPath(rope); ctx.setLineWidth(10); ctx.setLineCap(.round)
ctx.setStrokeColor(NSColor(srgbRed: 0.36, green: 0.27, blue: 0.24, alpha: 1).cgColor); ctx.strokePath()

// Three prints hanging from the line, each slightly tilted, white border, soft shadow.
let prints: [(x: CGFloat, w: CGFloat, h: CGFloat, tilt: CGFloat, fill: NSColor)] = [
  (250, 200, 165, 5, NSColor(srgbRed: 0.33, green: 0.62, blue: 0.86, alpha: 1)),
  (512, 230, 190, -2, NSColor(srgbRed: 0.24, green: 0.25, blue: 0.30, alpha: 1)),
  (774, 200, 165, -6, NSColor(srgbRed: 0.40, green: 0.75, blue: 0.56, alpha: 1)),
]
for p in prints {
  let top = lineY(p.x)
  ctx.saveGState()
  ctx.translateBy(x: p.x, y: top)
  ctx.rotate(by: p.tilt * .pi / 180)
  let frame = CGRect(x: -p.w / 2, y: -p.h - 6, width: p.w, height: p.h)
  ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 18, color: NSColor.black.withAlphaComponent(0.30).cgColor)
  ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 12, cornerHeight: 12, transform: nil))
  ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
  ctx.setShadow(offset: .zero, blur: 0, color: nil)
  let inner = frame.insetBy(dx: 14, dy: 14).offsetBy(dx: 0, dy: 6).insetBy(dx: 0, dy: 6)
  ctx.addPath(CGPath(roundedRect: inner, cornerWidth: 6, cornerHeight: 6, transform: nil))
  ctx.setFillColor(p.fill.cgColor); ctx.fillPath()
  // A few "text lines" so the prints read as screenshots.
  ctx.setFillColor(NSColor.white.withAlphaComponent(0.75).cgColor)
  for i in 0..<3 {
    let w = inner.width * [0.62, 0.45, 0.54][i]
    ctx.fill(CGRect(x: inner.minX + 18, y: inner.maxY - 34 - CGFloat(i) * 30, width: w, height: 12))
  }
  // Two wooden pegs gripping the line.
  for dx in [-p.w / 2 + 34, p.w / 2 - 34] {
    let peg = CGRect(x: dx - 11, y: -38, width: 22, height: 58)
    ctx.addPath(CGPath(roundedRect: peg, cornerWidth: 6, cornerHeight: 6, transform: nil))
    ctx.setFillColor(NSColor(srgbRed: 0.80, green: 0.62, blue: 0.42, alpha: 1).cgColor); ctx.fillPath()
    ctx.setFillColor(NSColor(srgbRed: 0.55, green: 0.40, blue: 0.27, alpha: 1).cgColor)
    ctx.fill(CGRect(x: dx - 11, y: -12, width: 22, height: 4))
  }
  ctx.restoreGState()
}
ctx.restoreGState()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print(out)
