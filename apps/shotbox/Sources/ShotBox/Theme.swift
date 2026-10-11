import AppKit
import SwiftUI

/// Change Detection palette. Dark is primary (slate graphite); light is a cool light table.
/// Cyan means new, orange means leaving. Selection and pin travel use white at 90%, never a colour.
enum Theme {
    /// Dark unless SHOTBOX_APPEARANCE=light. An app-only override; the system appearance is never touched.
    static let scheme: ColorScheme = ProcessInfo.processInfo.environment["SHOTBOX_APPEARANCE"] == "light" ? .light : .dark

    private static func dyn(_ dark: UInt32, _ light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let v = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        })
    }

    static let sheet = dyn(0x0F1418, 0xE9EEF1)
    static let panel = dyn(0x161D23, 0xF6F9FA)
    static let hairline = dyn(0x26313A, 0xC9D3D9)
    static let ink = dyn(0xF2F5F7, 0x0E1519)
    static let cyan = dyn(0x3FD0E0, 0x0E8FA0)
    static let orange = dyn(0xFF7A3D, 0xD9531A)
    /// Selection and pin travel: white at 90% on dark, ink on light.
    static let select = ink.opacity(0.9)

    static let meta = ink.opacity(0.6)
    static let coord = ink.opacity(0.4)

    static func mono(_ size: CGFloat = 11, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced).monospacedDigit()
    }
}

/// 10 pt uppercase section label, +0.12 em tracking.
struct SectionLabel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundStyle(Theme.meta)
    }
}

extension View {
    func sectionLabel() -> some View { modifier(SectionLabel()) }
}

/// Four registration ticks at the corners of a rect.
struct RegistrationTicks: View {
    var length: CGFloat = 7
    var body: some View {
        GeometryReader { geo in
            Path { p in
                let w = geo.size.width, h = geo.size.height
                for (x, y, dx, dy) in [(0.0, 0.0, 1.0, 1.0), (w, 0, -1, 1), (0, h, 1, -1), (w, h, -1, -1)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
                    p.move(to: CGPoint(x: x + dx * length, y: y)); p.addLine(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x, y: y + dy * length))
                }
            }
            .stroke(Theme.select, lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

/// A shortcut drawn as key caps.
struct KeyCaps: View {
    let keys: [String]
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                Text(k)
                    .font(Theme.mono(11, .medium))
                    .foregroundStyle(Theme.ink.opacity(0.9))
                    .frame(minWidth: 20, minHeight: 20)
                    .padding(.horizontal, 2)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.hairline, lineWidth: 1))
                    .shadow(color: .black.opacity(0.25), radius: 0, y: 1)
            }
        }
    }
}
