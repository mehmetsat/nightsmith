import AppKit
import SwiftUI

/// Every animation of the Clothesline. The line itself (rope, pegs, prints) moves as Core Animation springs on layers
/// built ahead of time: each event adds its animations once and the render server runs them, so nothing on the main
/// thread redraws per frame. The controls around it (basket, peek, hover, search) use SwiftUI springs.
/// Reduce Motion swaps the line's motion for 0.2 s cross-fades and drops the swing.
enum LineMotion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Reduce Motion: the line cross-fades in and out.
    static let fadeDuration = 0.2
    static var fade: Animation { .easeInOut(duration: fadeDuration) }

    // MARK: The line (Core Animation)

    /// The drop: each print falls from above the screen's top edge on response 0.30, damping 0.70: one overshoot of
    /// about 12 pt past its pegs, within 2 % of rest 0.29 s after it starts.
    static let dropResponse = 0.30
    static let dropDamping = 0.70
    static let dropSettle = 0.29
    /// When a falling print first reaches its resting height, after it starts: the swing takes over from there.
    static let landing = 0.12
    /// The rope sags from 2 pt to its rest depth on a looser spring, so it visibly bounces once as the weight lands.
    static let ropeResponse = 0.36
    static let ropeDamping = 0.5
    /// Prints start 15 ms apart, outward from the pointer; the whole stagger never exceeds 60 ms.
    static let stagger = 0.015
    static let maxStagger = 0.06
    /// The swing about the pegs once a print lands: stiffness 140, damping 9, from 3–5° off its resting tilt (8° for
    /// a new arrival). It crosses rest twice and is still about 0.7 s after landing.
    static let swingStiffness: CGFloat = 140
    static let swingDamping: CGFloat = 9
    static let arrivalSwing: CGFloat = 8 * .pi / 180

    /// 3° to 5°, the same for a capture on every open.
    static func releaseSwing(_ id: Int64) -> CGFloat {
        var x = UInt64(bitPattern: id) &* 0x9E37_79B9_7F4A_7C15
        x ^= x >> 29
        return (3 + 2 * CGFloat(x % 1000) / 999) * .pi / 180
    }

    static func pendulum(from: CGFloat, to: CGFloat, begin: CFTimeInterval) -> CASpringAnimation {
        let a = CASpringAnimation(keyPath: "transform.rotation.z")
        a.mass = 1
        a.stiffness = swingStiffness
        a.damping = swingDamping
        a.fromValue = from
        a.toValue = to
        a.beginTime = begin
        a.fillMode = .backwards
        a.duration = a.settlingDuration
        return a
    }

    /// Hover: 6 pt up and 1.035 times the size, on a 160 ms spring.
    static let liftResponse = 0.2
    static let liftDamping = 0.78
    static var liftTransform: CATransform3D {
        CATransform3DScale(CATransform3DMakeTranslation(0, 6, 0), 1.035, 1.035, 1)
    }

    /// Retract: 170 ms ease-in (0.4, 0, 1, 1), straight up, outermost first, no bounce.
    static let retractDuration = 0.17
    static let retractStagger = 0.008
    static var retractCurve: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1) }
    /// Prints moving along the rope during a search or for a new arrival.
    static let reflowResponse = 0.32
    static let reflowDamping = 0.82
    /// The accent glow round a new arrival fades over 1.5 s once it has landed.
    static let glowFade = 1.5

    /// A Core Animation spring with SwiftUI's response and damping fraction, run until it is still.
    static func spring(_ keyPath: String, response: Double, damping: Double) -> CASpringAnimation {
        let a = CASpringAnimation(keyPath: keyPath)
        a.mass = 1
        a.stiffness = pow(2 * .pi / response, 2)
        a.damping = 4 * .pi * damping / response
        a.duration = a.settlingDuration
        return a
    }

    // MARK: The controls (SwiftUI)

    /// Hover lift, matching the layers' 160 ms spring.
    static var lift: Animation { reduced ? .easeOut(duration: 0.12) : .spring(response: liftResponse, dampingFraction: liftDamping) }
    static var reflow: Animation { reduced ? fade : .spring(response: reflowResponse, dampingFraction: reflowDamping) }
    /// The basket opens below the line.
    static var basket: Animation { reduced ? fade : .spring(response: 0.4, dampingFraction: 0.84) }
    /// A print coming forward to be read, and going back on the line.
    static var peek: Animation { reduced ? fade : .spring(response: 0.34, dampingFraction: 0.78) }
    /// The basket tag's swing as the line lands.
    static var tagSwing: Animation { .interpolatingSpring(stiffness: Double(swingStiffness), damping: Double(swingDamping)) }

    /// How long the copied print's tug and "Copied" show before the line tucks away: the line is gone 0.7 s after
    /// the click, with the pasteboard already filled.
    static let copiedHold = 0.5
    /// The white flash across a copied print.
    static let flash = 0.12
}

/// SHOTBOX_TRACE=<path>: timestamped lines QA reads to measure the line's latency. Off unless the variable is set.
enum ClotheslineTrace {
    private static let url: URL? = ProcessInfo.processInfo.environment["SHOTBOX_TRACE"].map { URL(fileURLWithPath: $0) }
    private static let queue = DispatchQueue(label: "shotbox.trace")

    static var enabled: Bool { url != nil }

    static func log(_ event: String) {
        guard let url else { return }
        let stamp = String(format: "%.3f", Date().timeIntervalSince1970)
        queue.async {
            let line = Data("\(stamp) \(event)\n".utf8)
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(line)
                try? h.close()
            } else {
                try? line.write(to: url)
            }
        }
    }
}
