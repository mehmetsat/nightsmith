import AppKit
import QuartzCore

/// The line as Core Animation layers: a soft scrim under the menubar, the rope, and each print with its paper, two
/// shadows and pegs. Everything is built while the line is hidden, with its picture already decoded at the size it
/// hangs, so opening only adds animations to layers that exist: each print falls from above the screen on its own
/// spring, 15 ms after its neighbour nearer the pointer, lands with one small overshoot and swings about its pegs to
/// rest while the rope bounces under the weight. The render server runs all of it; the main thread draws nothing per
/// frame.
///
/// The stage never takes the mouse and is not in the accessibility tree: SwiftUI proxies laid over it at the same
/// places (see `LineView`) take clicks, hover and drags and carry the accessibility elements.
///
/// Coordinates are Core Animation's own, y up from the bottom of the stage; `up(_:)` turns a height measured down
/// from the window's top (as `LineLayout` gives it) into one.
final class LineStage: NSView {
    private let host = CALayer()
    /// Everything; fully clear while the line is hidden.
    private let content = CALayer()
    /// The scrim and the rope: they fade as the line goes up, the prints just rise out of view.
    private let cord = CALayer()
    private let wash = CAGradientLayer()
    private let tint = CAGradientLayer()
    private let tintMask = CAGradientLayer()
    private let rope = CAShapeLayer()
    private let underside = CAShapeLayer()
    private var prints: [Int64: PrintLayers] = [:]
    private(set) var hung = LineLayout.empty
    private weak var state: ClotheslineState?
    private var shown = false
    /// The order the prints fell in, nearest the pointer first; they go up the other way round.
    private var dropOrder: [Int64] = []
    private var marksPending = false
    private var laidOutSize = CGSize.zero

    init(state: ClotheslineState) {
        self.state = state
        super.init(frame: .zero)
        layer = host
        wantsLayer = true
        host.masksToBounds = false
        content.opacity = 0
        host.addSublayer(content)
        content.addSublayer(cord)
        cord.addSublayer(wash)
        cord.addSublayer(tint)
        tint.mask = tintMask
        cord.addSublayer(rope)
        cord.addSublayer(underside)
        for l in [rope, underside] {
            l.fillColor = nil
            l.lineCap = .round
            l.lineJoin = .round
        }
        // 1.5 pt of cord with its shadow 2 pt below, blur 3, so it holds on a pale wallpaper.
        rope.lineWidth = 1.5
        rope.shadowColor = NSColor.black.cgColor
        rope.shadowOpacity = 0.22
        rope.shadowRadius = 1.5
        rope.shadowOffset = CGSize(width: 0, height: -2)
        // A 0.5 pt darker underside along the bottom of the cord, so it reads round.
        underside.lineWidth = 0.5
        underside.transform = CATransform3DMakeTranslation(0, -0.55, 0)
        // A faint cool-to-warm cast across the scrim, like tinted glass, fading with it.
        tint.startPoint = CGPoint(x: 0, y: 0.5)
        tint.endPoint = CGPoint(x: 1, y: 0.5)
        tintMask.startPoint = CGPoint(x: 0.5, y: 1)
        tintMask.endPoint = CGPoint(x: 0.5, y: 0)
        tintMask.colors = [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0.5), CGColor(gray: 0, alpha: 0)]
        tintMask.locations = [0, 0.5, 1]
        wash.startPoint = CGPoint(x: 0.5, y: 1)
        wash.endPoint = CGPoint(x: 0.5, y: 0)
        wash.locations = [0, 0.5, 1]
        restyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }

    private var height: CGFloat { bounds.height }
    private func up(_ y: CGFloat) -> CGFloat { height - y }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    override func layout() {
        super.layout()
        relayout()
    }

    /// Fits the layers to the stage's size; the window only ever changes size while the line is hidden.
    private func relayout() {
        guard bounds.size != laidOutSize else { return }
        laidOutSize = bounds.size
        quietly {
            content.frame = bounds
            cord.frame = bounds
            rope.frame = bounds
            underside.frame = bounds
        }
        apply(hung, animated: false, fromLeft: false)
    }

    /// The scrim reaches 70 pt past the lowest print, at least 200 pt, and fades to nothing: no hard edge anywhere.
    private func fitWash() {
        let depth = min(max(hung.lowest + 70, 200), height)
        let frame = CGRect(x: 0, y: height - depth, width: bounds.width, height: depth)
        for l in [wash, tint, tintMask] where l.frame != (l === tintMask ? CGRect(origin: .zero, size: frame.size) : frame) {
            l.frame = l === tintMask ? CGRect(origin: .zero, size: frame.size) : frame
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        quietly {
            rope.contentsScale = scale
            underside.contentsScale = scale
            for p in prints.values { p.setScale(scale) }
        }
    }

    private var dark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    private func restyle() {
        let dark = dark
        quietly {
            // #C7C7CC in dark, #8A8A8E in light; the underside a shade deeper.
            rope.strokeColor = dark ? CGColor(srgbRed: 0xC7 / 255, green: 0xC7 / 255, blue: 0xCC / 255, alpha: 1)
                : CGColor(srgbRed: 0x8A / 255, green: 0x8A / 255, blue: 0x8E / 255, alpha: 1)
            underside.strokeColor = dark ? CGColor(srgbRed: 0x8E / 255, green: 0x8E / 255, blue: 0x93 / 255, alpha: 1)
                : CGColor(srgbRed: 0x5A / 255, green: 0x5A / 255, blue: 0x5E / 255, alpha: 1)
            // White at 35 % to nothing in light, black at 25 % in dark.
            let ink = dark ? CGColor(gray: 0, alpha: 0.25) : CGColor(gray: 1, alpha: 0.35)
            wash.colors = [ink, ink.copy(alpha: ink.alpha * 0.45) ?? ink, ink.copy(alpha: 0) ?? ink]
            let a: CGFloat = dark ? 0.07 : 0.10
            tint.colors = [CGColor(srgbRed: 0.55, green: 0.62, blue: 1, alpha: a),
                           CGColor(srgbRed: 0.8, green: 0.72, blue: 1, alpha: a * 0.6),
                           CGColor(srgbRed: 1, green: 0.66, blue: 0.68, alpha: a)]
            for p in prints.values { p.style(dark: dark) }
        }
    }

    private func quietly(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    // MARK: Layout

    private func path(_ curve: RopeCurve) -> CGPath {
        let p = CGMutablePath()
        let pts = curve.points().map { CGPoint(x: $0.x, y: up($0.y)) }
        p.addLines(between: pts)
        return p
    }

    private func setRope(_ to: CGPath, animation: CAPropertyAnimation? = nil) {
        for l in [rope, underside] {
            if let animation {
                let a = animation.copy() as! CAPropertyAnimation
                if let b = a as? CABasicAnimation, b.fromValue == nil { b.fromValue = l.presentation()?.path ?? l.path }
                l.add(a, forKey: "path")
            }
            l.path = to
        }
    }

    /// Hangs `new` on the line. While the line is down, prints that stay slide to their new places, prints that
    /// leave unpeg from one corner and fall away, and new ones are carried in from the left (a new capture) or
    /// hung back from above (a search cleared). While hidden, everything is just put in place.
    func apply(_ new: LineLayout, animated: Bool, fromLeft: Bool) {
        hung = new
        guard height > 0 else { return }
        let animate = animated && shown && !LineMotion.reduced
        let dark = dark
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fitWash()
        let reflow = LineMotion.spring("", response: LineMotion.reflowResponse, damping: LineMotion.reflowDamping)
        if animate {
            let a = LineMotion.spring("path", response: LineMotion.reflowResponse, damping: LineMotion.reflowDamping)
            setRope(path(new.rope), animation: a)
        } else {
            setRope(path(new.rope))
        }
        var keep: Set<Int64> = []
        let scale = window?.backingScaleFactor ?? 2
        for place in new.prints {
            keep.insert(place.id)
            if let p = prints[place.id] {
                let fromPos = p.hang.presentation()?.position ?? p.hang.position
                let fromTurn = p.swing.presentation()?.value(forKeyPath: "transform.rotation.z") as? CGFloat
                let wasSize = p.place.size
                p.place = place
                p.build(height: height, dark: dark)
                if wasSize != place.size { loadImage(p) }
                guard animate else { continue }
                p.hang.removeAnimation(forKey: "drop")
                let move = reflow.copy() as! CASpringAnimation
                move.keyPath = "position"
                move.fromValue = NSValue(point: fromPos)
                p.hang.add(move, forKey: "reflow")
                let turn = reflow.copy() as! CASpringAnimation
                turn.keyPath = "transform.rotation.z"
                turn.fromValue = fromTurn ?? p.restTurn
                turn.toValue = p.restTurn
                p.swing.add(turn, forKey: "swing")
            } else {
                let p = PrintLayers(place: place)
                p.setScale(scale)
                p.build(height: height, dark: dark)
                p.hang.zPosition = 1
                content.addSublayer(p.hang)
                prints[place.id] = p
                loadImage(p)
                guard animate else { continue }
                if fromLeft {
                    // A new arrival: carried in from the left and dropped on, tipped 8° so it swings in wide.
                    let move = reflow.copy() as! CASpringAnimation
                    move.keyPath = "position"
                    move.fromValue = NSValue(point: CGPoint(x: p.hang.position.x - 320, y: p.hang.position.y + 40))
                    p.hang.add(move, forKey: "reflow")
                    p.swing.add(LineMotion.pendulum(from: p.restTurn + LineMotion.arrivalSwing, to: p.restTurn,
                                                    begin: CACurrentMediaTime() + 0.08), forKey: "swing")
                } else {
                    // Hung back from just above.
                    let move = reflow.copy() as! CASpringAnimation
                    move.keyPath = "position"
                    move.fromValue = NSValue(point: CGPoint(x: p.hang.position.x, y: p.hang.position.y + 30))
                    p.hang.add(move, forKey: "reflow")
                    let turn = reflow.copy() as! CASpringAnimation
                    turn.keyPath = "transform.rotation.z"
                    turn.fromValue = p.restTurn
                    turn.toValue = p.restTurn
                    p.swing.add(turn, forKey: "swing")
                }
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.duration = 0.2
                p.swing.add(fade, forKey: "in")
            }
        }
        for (id, p) in prints where !keep.contains(id) {
            prints[id] = nil
            guard animate else {
                p.hang.removeFromSuperlayer()
                continue
            }
            // Unpegged at one corner: it turns about the other and drops softly out of view.
            let group = CAAnimationGroup()
            let fall = CABasicAnimation(keyPath: "position.y")
            fall.byValue = -90
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.toValue = 0
            group.animations = [fall, fade]
            group.duration = 0.32
            group.timingFunction = CAMediaTimingFunction(name: .easeIn)
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.byValue = -12 * CGFloat.pi / 180
            turn.duration = 0.32
            turn.timingFunction = CAMediaTimingFunction(name: .easeIn)
            turn.fillMode = .forwards
            turn.isRemovedOnCompletion = false
            p.hang.zPosition = 0
            CATransaction.begin()
            CATransaction.setCompletionBlock { p.hang.removeFromSuperlayer() }
            p.hang.add(group, forKey: "unpeg")
            p.swing.add(turn, forKey: "unpeg")
            CATransaction.commit()
        }
        CATransaction.commit()
        refreshMarks()
    }

    /// Sets a print's picture from the copy decoded at its size; if that is not ready (only ever while hidden, right
    /// after a capture), the thumbnail stands in until it is.
    private func loadImage(_ p: PrintLayers) {
        guard let store = state?.store else { return }
        let c = p.place.capture
        if let sharp = PrintImages.sharp(c, store: store) {
            quietly { p.photo.contents = sharp.cgImage(forProposedRect: nil, context: nil, hints: nil) }
            return
        }
        if let thumb = Images.cached(store.thumbURL(c)) {
            quietly { p.photo.contents = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        }
        Task { @MainActor [weak p] in
            guard let image = await PrintImages.load(c, store: store), let p else { return }
            p.photo.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
    }

    // MARK: Drop and retract

    /// Brings the line down. Returns how long until the last print is within 2 % of rest.
    @discardableResult
    func drop(pointerX: CGFloat?, fresh: Set<Int64>) -> Double {
        shown = true
        let now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let inFlight = Dictionary(uniqueKeysWithValues: prints.map { ($0.key, $0.value.hang.animation(forKey: "retract") != nil
            ? $0.value.hang.presentation()?.position.y : nil) })
        content.removeAllAnimations()
        cord.removeAllAnimations()
        for p in prints.values { p.reset() }
        content.opacity = 1
        let px = pointerX ?? bounds.midX
        let order = hung.prints.sorted { abs($0.centre - px) < abs($1.centre - px) }
        dropOrder = order.map(\.id)

        if LineMotion.reduced {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.duration = LineMotion.fadeDuration
            content.add(fade, forKey: "fade")
            CATransaction.commit()
            return LineMotion.fadeDuration
        }

        let wash = CABasicAnimation(keyPath: "opacity")
        wash.fromValue = 0
        wash.duration = 0.18
        cord.add(wash, forKey: "in")

        // The rope comes in all but straight, 2 pt of sag, and bounces once as the prints' weight lands on it.
        let sag = LineMotion.spring("path", response: LineMotion.ropeResponse, damping: LineMotion.ropeDamping)
        sag.fromValue = path(.taut(width: bounds.width))
        sag.beginTime = now + 0.06
        sag.fillMode = .backwards
        for l in [rope, underside] { l.removeAllAnimations() }
        setRope(path(hung.rope), animation: sag)

        let step = order.count > 1 ? min(LineMotion.stagger, LineMotion.maxStagger / Double(order.count - 1)) : 0
        for (i, place) in order.enumerated() {
            guard let p = prints[place.id] else { continue }
            let begin = now + Double(i) * step
            let fall = LineMotion.spring("position.y", response: LineMotion.dropResponse, damping: LineMotion.dropDamping)
            // From wholly above the window: the print's top edge starts (its height + 24) pt over the screen's top.
            fall.fromValue = inFlight[place.id].flatMap { $0 } ?? (height + place.size.height + 24)
            fall.beginTime = begin
            fall.fillMode = .backwards
            p.hang.add(fall, forKey: "drop")
            // Released tipped 3–5° one way or the other, alternating along the line (8° for a new arrival); it falls
            // tipped, and once it lands it swings about its pegs to its resting tilt.
            let side: CGFloat = place.index.isMultiple(of: 2) ? 1 : -1
            let tip = fresh.contains(place.id) ? LineMotion.arrivalSwing : LineMotion.releaseSwing(place.id)
            p.swing.add(LineMotion.pendulum(from: p.restTurn + side * tip, to: p.restTurn,
                                            begin: begin + LineMotion.landing), forKey: "swing")
            if fresh.contains(place.id) { glow(p, after: begin + LineMotion.dropSettle * 0.6) }
        }
        CATransaction.commit()
        return step * Double(max(order.count - 1, 0)) + LineMotion.dropSettle
    }

    /// A soft accent glow round a new arrival, fading out over 1.5 s.
    func glow(_ id: Int64) {
        guard let p = prints[id] else { return }
        glow(p, after: CACurrentMediaTime() + 0.25)
    }

    private func glow(_ p: PrintLayers, after begin: CFTimeInterval) {
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [0.35, 0.35, 0]
        a.keyTimes = [0, 0.15, 1]
        a.duration = LineMotion.glowFade
        a.beginTime = begin
        a.fillMode = .backwards
        a.timingFunctions = [CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeInEaseOut)]
        p.glow.add(a, forKey: "glow")
    }

    /// Copy: the print is tugged 8 pt down off its pegs and springs back.
    func tug(_ id: Int64) {
        guard let p = prints[id], !LineMotion.reduced else { return }
        let a = CASpringAnimation(keyPath: "position.y")
        a.mass = 1
        a.stiffness = 400
        a.damping = 18
        a.fromValue = -8
        a.toValue = 0
        a.isAdditive = true
        a.duration = a.settlingDuration
        p.hang.add(a, forKey: "tug")
    }

    /// Puts the line away: 170 ms ease-in straight up, the outermost prints first, no bounce. `gone` runs once
    /// nothing is drawn, unless the line was called down again in the meantime.
    func retract(gone: @escaping () -> Void) {
        shown = false
        let now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, !self.shown else { return }
            self.quietly {
                self.content.opacity = 0
                self.content.removeAllAnimations()
                self.cord.removeAllAnimations()
                for p in self.prints.values { p.reset() }
                self.setRope(self.path(self.hung.rope))
            }
            gone()
        }
        if LineMotion.reduced {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = content.presentation()?.opacity ?? 1
            fade.toValue = 0
            fade.duration = LineMotion.fadeDuration
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            content.add(fade, forKey: "fade")
            CATransaction.commit()
            return
        }
        let order = dropOrder.reversed().compactMap { prints[$0] } + prints.values.filter { !dropOrder.contains($0.id) }
        let curve = LineMotion.retractCurve
        for (i, p) in order.enumerated() {
            let rise = CABasicAnimation(keyPath: "position.y")
            rise.fromValue = p.hang.presentation()?.position.y ?? p.hang.position.y
            rise.toValue = height + p.place.size.height + 40
            rise.duration = LineMotion.retractDuration
            rise.timingFunction = curve
            rise.beginTime = now + Double(i) * LineMotion.retractStagger
            rise.fillMode = .both
            rise.isRemovedOnCompletion = false
            p.hang.removeAnimation(forKey: "drop")
            p.hang.removeAnimation(forKey: "reflow")
            p.hang.removeAnimation(forKey: "tug")
            p.hang.add(rise, forKey: "retract")
        }
        let total = LineMotion.retractDuration + Double(max(order.count - 1, 0)) * LineMotion.retractStagger
        for l in [rope, underside] {
            let a = CABasicAnimation(keyPath: "path")
            a.fromValue = l.presentation()?.path ?? l.path
            a.toValue = path(.taut(width: bounds.width))
            a.duration = LineMotion.retractDuration
            a.timingFunction = curve
            a.fillMode = .forwards
            a.isRemovedOnCompletion = false
            l.removeAnimation(forKey: "path")
            l.add(a, forKey: "path")
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = total
        fade.timingFunction = curve
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        cord.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    // MARK: Marks

    /// Hover and focus lift a print 6 pt and scale it to 1.035 with a deeper shadow, and open its pegs 4°; a print
    /// pulled forward as the peek or dragged away fades; an unseen capture wears an accent dot on its peg.
    /// Coalesced to one pass per run-loop turn.
    func setNeedsMarks() {
        guard !marksPending else { return }
        marksPending = true
        DispatchQueue.main.async { [weak self] in
            self?.marksPending = false
            self?.refreshMarks()
        }
    }

    private func refreshMarks() {
        guard let state else { return }
        let dark = dark
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        for p in prints.values {
            let lifted = state.isLifted(p.id)
            if lifted != p.lifted {
                p.lifted = lifted
                p.style(dark: dark)
                p.hang.zPosition = lifted ? 2 : 1
                let to = lifted ? LineMotion.liftTransform : CATransform3DIdentity
                if LineMotion.reduced {
                    p.hang.transform = to
                } else {
                    let lift = LineMotion.spring("transform", response: LineMotion.liftResponse, damping: LineMotion.liftDamping)
                    lift.fromValue = NSValue(caTransform3D: p.hang.presentation()?.transform ?? p.hang.transform)
                    lift.toValue = NSValue(caTransform3D: to)
                    p.hang.add(lift, forKey: "lift")
                    quietly { p.hang.transform = to }
                    p.openPegs(lifted)
                }
            }
            let presence: Float = state.peekID == p.id ? 0 : state.takenID == p.id ? 0.35 : state.peekID == nil ? 1 : 0.55
            if p.hang.opacity != presence { p.hang.opacity = presence }
            let fresh: Float = state.unseen.contains(p.id) ? 1 : 0
            if p.dot.opacity != fresh { p.dot.opacity = fresh }
        }
        CATransaction.commit()
    }
}

/// The layers of one print. `hang` carries its place on the rope, the drop and the hover lift; `swing`, inside it,
/// turns about the top centre for the pendulum; the paper, its two shadows and its pegs ride inside that.
private final class PrintLayers {
    let hang = CALayer()
    let swing = CALayer()
    let glow = CALayer()
    /// The ambient shadow, wide and soft, that lifts the print off the wallpaper.
    let ambient = CALayer()
    /// The contact shadow, tight under the paper's edge, that holds it on white.
    let contact = CALayer()
    /// The paper: 5 pt border, 6 pt corners, a 0.5 pt hairline (a 1.5 pt accent ring when pinned).
    let card = CALayer()
    /// The screenshot itself, inside the border.
    let photo = CALayer()
    var pegs: [CALayer] = []
    private var pegTurns: [CGFloat] = []
    let dot = CALayer()
    var place: PrintPlace
    var lifted = false
    private var builtPegs: [PegPlace] = []
    private var builtPinned: Bool?

    var id: Int64 { place.id }
    /// The resting turn, in Core Animation's sense (counter-clockwise positive).
    var restTurn: CGFloat { -CGFloat(place.tilt) * .pi / 180 }

    init(place: PrintPlace) {
        self.place = place
        hang.anchorPoint = CGPoint(x: 0.5, y: 1)
        swing.anchorPoint = CGPoint(x: 0.5, y: 1)
        hang.addSublayer(swing)
        for l in [glow, ambient, contact] {
            l.shadowOffset = .zero
            l.shadowColor = NSColor.black.cgColor
            swing.addSublayer(l)
        }
        glow.shadowColor = NSColor.controlAccentColor.cgColor
        glow.shadowRadius = 12
        glow.shadowOpacity = 1
        glow.opacity = 0
        contact.shadowRadius = 1
        contact.shadowOffset = CGSize(width: 0, height: -1)
        card.cornerRadius = PrintMetrics.cornerRadius
        card.cornerCurve = .continuous
        card.masksToBounds = true
        swing.addSublayer(card)
        photo.cornerRadius = PrintMetrics.pictureRadius
        photo.masksToBounds = true
        photo.contentsGravity = .resizeAspect
        photo.minificationFilter = .trilinear
        card.addSublayer(photo)
        // The new-arrival dot: 6 pt of accent with a white rim, on the first peg.
        dot.bounds = CGRect(x: 0, y: 0, width: 6, height: 6)
        dot.cornerRadius = 3
        dot.backgroundColor = NSColor.controlAccentColor.cgColor
        dot.borderColor = CGColor(gray: 1, alpha: 0.9)
        dot.borderWidth = 1
        dot.shadowColor = NSColor.black.cgColor
        dot.shadowOpacity = 0.3
        dot.shadowRadius = 1
        dot.shadowOffset = CGSize(width: 0, height: -0.5)
        dot.opacity = 0
    }

    func setScale(_ scale: CGFloat) {
        for l in [hang, swing, card, photo, dot] { l.contentsScale = scale }
    }

    /// Clears every animation, for a fresh drop or once the line is up.
    func reset() {
        hang.removeAllAnimations()
        swing.removeAllAnimations()
        glow.removeAllAnimations()
        pegs.forEach { $0.removeAllAnimations() }
        if lifted {
            lifted = false
            hang.transform = CATransform3DIdentity
            for (peg, turn) in zip(pegs, pegTurns) { peg.transform = CATransform3DMakeRotation(turn, 0, 0, 1) }
        }
    }

    /// Paper #FBFAF7 with a black 12 % hairline in light, #2C2C2E with a white 10 % one in dark. Two shadows: contact
    /// y 1, blur 2, 20 %; ambient y 10, blur 22, 18 % (y 12, blur 28, 45 % in dark), deeper and softer while lifted.
    func style(dark: Bool) {
        let pinned = place.capture.pinned
        card.backgroundColor = dark ? CGColor(srgbRed: 0x2C / 255, green: 0x2C / 255, blue: 0x2E / 255, alpha: 1)
            : CGColor(srgbRed: 0xFB / 255, green: 0xFA / 255, blue: 0xF7 / 255, alpha: 1)
        card.borderWidth = pinned ? 1.5 : 0.5
        card.borderColor = pinned ? NSColor.controlAccentColor.cgColor
            : dark ? CGColor(gray: 1, alpha: 0.1) : CGColor(gray: 0, alpha: 0.12)
        contact.shadowOpacity = dark ? 0.4 : 0.2
        if lifted {
            ambient.shadowOpacity = dark ? 0.55 : 0.28
            ambient.shadowRadius = 15
            ambient.shadowOffset = CGSize(width: 0, height: -14)
        } else {
            ambient.shadowOpacity = dark ? 0.45 : 0.18
            ambient.shadowRadius = dark ? 14 : 11
            ambient.shadowOffset = CGSize(width: 0, height: dark ? -12 : -10)
        }
    }

    /// Puts every layer at rest for `place`, on a stage `height` tall.
    @MainActor
    func build(height: CGFloat, dark: Bool) {
        let s = place.size
        let bounds = CGRect(origin: .zero, size: s)
        hang.bounds = bounds
        hang.position = CGPoint(x: place.centre, y: height - place.top)
        swing.bounds = bounds
        swing.position = CGPoint(x: s.width / 2, y: s.height)
        swing.transform = CATransform3DMakeRotation(restTurn, 0, 0, 1)
        let shape = CGPath(roundedRect: bounds, cornerWidth: PrintMetrics.cornerRadius,
                           cornerHeight: PrintMetrics.cornerRadius, transform: nil)
        for l in [glow, ambient, contact, card] { l.frame = bounds }
        glow.shadowPath = shape
        ambient.shadowPath = shape
        contact.shadowPath = shape
        let b = PrintMetrics.border
        photo.frame = bounds.insetBy(dx: b, dy: b)
        style(dark: dark)
        buildPegs()
    }

    @MainActor
    private func buildPegs() {
        let pinned = place.capture.pinned
        let s = place.size
        if builtPinned != pinned || builtPegs.count != place.pegs.count {
            pegs.forEach { $0.removeFromSuperlayer() }
            pegs = place.pegs.map { _ in CALayer() }
            for peg in pegs {
                peg.shadowColor = NSColor.black.cgColor
                peg.shadowOpacity = 0.35
                peg.shadowRadius = 0.7
                peg.shadowOffset = CGSize(width: 0.3, height: -1)
                swing.addSublayer(peg)
            }
            builtPinned = pinned
            dot.removeFromSuperlayer()
            if !pinned, let first = pegs.first { first.addSublayer(dot) }
        }
        builtPegs = place.pegs
        let pad = PegArt.pad
        pegTurns = []
        for (peg, at) in zip(pegs, place.pegs) {
            let size = pinned ? SteelClip.size : WoodPeg.size
            let ropeY = pinned ? SteelClip.ropeY : WoodPeg.ropeY
            let box = CGSize(width: size.width + 2 * pad, height: size.height + 2 * pad)
            peg.contents = pinned ? PegArt.clip : PegArt.peg(at.look)
            peg.contentsScale = 3
            peg.bounds = CGRect(origin: .zero, size: box)
            // Turned about the point where the rope runs through the jaws, which sits on the rope.
            peg.anchorPoint = CGPoint(x: 0.5, y: 1 - (pad + ropeY) / box.height)
            peg.position = CGPoint(x: at.x, y: s.height + at.ropeY)
            let turn = pinned ? 0 : -CGFloat(at.look.angle) * .pi / 180
            pegTurns.append(turn)
            peg.transform = CATransform3DMakeRotation(turn, 0, 0, 1)
        }
        // The new-arrival dot sits on the lower leg of the first peg.
        dot.position = CGPoint(x: pad + WoodPeg.size.width / 2, y: pad + 5)
    }

    /// Hover: two pegs splay 4° outward, as if pinched to lift the print; a single peg or the clip stays put.
    func openPegs(_ open: Bool) {
        guard pegs.count == 2 else { return }
        for (k, peg) in pegs.enumerated() {
            let splay: CGFloat = open ? (k == 0 ? -4 : 4) * .pi / 180 : 0
            let to = pegTurns[k] + splay
            let a = LineMotion.spring("transform.rotation.z", response: LineMotion.liftResponse, damping: 0.6)
            a.fromValue = peg.presentation()?.value(forKeyPath: "transform.rotation.z") as? CGFloat ?? pegTurns[k]
            a.toValue = to
            peg.add(a, forKey: "open")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            peg.transform = CATransform3DMakeRotation(to, 0, 0, 1)
            CATransaction.commit()
        }
    }
}
