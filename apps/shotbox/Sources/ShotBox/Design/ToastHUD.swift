import AppKit
import SwiftUI

/// "Copied" confirmation shown outside ShotBox's windows, so it stays visible after the Clothesline retracts.
final class ToastHUD {
    private let panel: NSPanel
    private let host: NSHostingView<ToastCapsule>
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        host = NSHostingView(rootView: ToastCapsule(text: ""))
        panel.contentView = host
    }

    func flash(_ text: String) {
        // On the screen the user is looking at: the one holding the pointer, where the line just was.
        guard !NSScreen.screens.isEmpty else { return }
        let screen = Clothesline.pointerScreen()
        host.rootView = ToastCapsule(text: text)
        panel.setFrame(NSRect(x: screen.frame.midX - 200, y: screen.visibleFrame.minY + 56, width: 400, height: 44), display: true)
        panel.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}

struct ToastCapsule: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(ChipFill())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("hudToast")
    }
}
