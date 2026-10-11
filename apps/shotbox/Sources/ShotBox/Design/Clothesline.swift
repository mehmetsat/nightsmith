import AppKit
import SwiftUI

/// The Clothesline: a borderless strip docked under the menubar. The newest captures hang from it by pegs.
/// The panel is on screen for the whole run, fixed at full size and fully clear: hidden, it draws nothing, ignores the
/// mouse and cannot become key; shown, everything that moves is drawn inside it. It is never moved, resized or ordered
/// out, so a recording that starts on it sees the whole drop.
/// ⌃⌥⌘L or resting the pointer on the top edge opens it. Esc, the hotkey, a click elsewhere or choosing a card closes it.
/// While it is down: typing searches, ↓ or a downward scroll opens the basket of older captures, ←/→ and Return pick one.
final class Clothesline {
    private let model: AppModel
    private let state: ClotheslineState
    private let panel: ClotheslinePanel
    /// The layers that draw the line, under the SwiftUI controls.
    private var stage: LineStage?
    private var host: NSView?
    /// The app that was in front before the line came down. Copying or closing hands the keyboard back to it, so ⌘V
    /// lands where the user was working.
    private var previousApp: NSRunningApplication?
    private(set) var isShown = false
    private var shownByPointer = false
    /// The screen the panel is fitted to. While hidden it follows the pointer, so it is already in place when called.
    private var screen: NSScreen?
    /// A screen to open on once the line has finished going up on the old one.
    private var pendingScreen: NSScreen?
    private var pendingByPointer = true
    private var dwell: DispatchWorkItem?
    private var dwellScreen: NSScreen?
    private var pointerMonitors: [Any] = []
    private var shownMonitors: [Any] = []
    private var pull: CGFloat = 0
    private var openWork: (decoded: Int, queries: Int)?

    /// How long the pointer rests on the top edge before the line comes down (the brief allows 150 ms).
    static let dwellTime = 0.12

    init(model: AppModel) {
        self.model = model
        state = ClotheslineState(model: model)
        panel = ClotheslinePanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = "Clothesline"
        panel.setAccessibilityTitle("Clothesline")
        panel.setAccessibilityLabel("Clothesline")
        panel.setAccessibilityIdentifier("clotheslinePanel")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        // A panel normally hides when its app deactivates; this one must stay on screen, clear, the whole time.
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // A click on the veil puts a peeked print back first; with nothing peeked it tucks the line away.
        state.onBackgroundTap = { [weak self] in
            guard let self else { return }
            if self.state.peekID != nil { self.state.peek(nil) } else { self.hide() }
        }
        // This init runs inside SwiftUI's own graph update (the model is a @StateObject). Hosting and laying out a
        // second SwiftUI tree there trips an AttributeGraph precondition and aborts the app at launch, so the content
        // goes in on the next turn of the run loop. From then on the panel is on screen, clear and click-through.
        DispatchQueue.main.async { [weak self] in self?.install() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            guard let self, !self.isShown else { return }
            self.fitPanel(on: Self.pointerScreen())
        }

        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
            self?.pointerMoved()
        }) { pointerMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            self?.pointerMoved()
            return event
        }) { pointerMonitors.append(local) }
    }

    private var installed = false

    private func install() {
        guard !installed else { return }
        installed = true
        let host = NSHostingView(rootView: ClotheslineView(state: state).environmentObject(model))
        // The panel's frame is set here, top-anchored; the content must never resize it.
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        // The line's layers sit under the controls and fill the window, so the scrim can fade out below the prints.
        let stage = LineStage(state: state)
        stage.autoresizingMask = [.width, .height]
        let container = NSView()
        container.addSubview(stage)
        container.addSubview(host)
        panel.contentView = container
        self.stage = stage
        self.host = host
        state.stage = stage
        fitPanel(on: Self.pointerScreen())
        panel.orderFrontRegardless()
        // Lay the line out now, while it is hidden, so its prints are built and decoded before the first drop.
        state.reload()
    }

    /// The screen that holds the pointer; the main screen if none does.
    static func pointerScreen() -> NSScreen {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.insetBy(dx: 0, dy: -1).contains(p) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Screens compared by display, not by object: AppKit hands out new NSScreen objects when the arrangement changes.
    private static func same(_ a: NSScreen?, _ b: NSScreen?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let x = a.deviceDescription[key] as? NSNumber, let y = b.deviceDescription[key] as? NSNumber { return x == y }
        return a.frame == b.frame
    }

    func toggle() {
        ClotheslineTrace.log("hotkey")
        isShown ? hide() : show()
    }

    func show(byPointer: Bool = false, on target: NSScreen? = nil) {
        if isShown { return }
        install()
        let screen = target ?? Self.pointerScreen()
        isShown = true
        shownByPointer = byPointer
        pendingScreen = nil
        cancelDwell()
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        // Normally a no-op: the hidden panel follows the pointer from screen to screen, so it is already there.
        if !Self.same(self.screen, screen) || panel.frame != frame(on: screen) { fitPanel(on: screen) }
        openWork = (PrintImages.decodeCount, state.queries)
        panel.exposed = true
        panel.ignoresMouseEvents = false
        // The prints start falling from where the pointer is, outward.
        let pointerX = NSEvent.mouseLocation.x - screen.frame.minX
        state.drop(pointerX: pointerX) { [weak self] in self?.settled() }
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        installShownMonitors()
        model.clotheslineOpen = true
        if ClotheslineTrace.enabled {
            // Commit the drop's first frame now rather than at the end of this run-loop turn, then note the time.
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            CATransaction.flush()
            ClotheslineTrace.log("clothesline.firstFrame screen=\(Int(screen.frame.minX)),\(Int(screen.frame.minY)) width=\(Int(screen.frame.width))")
        }
    }

    private func settled() {
        guard isShown, let start = openWork else { return }
        openWork = nil
        ClotheslineTrace.log("clothesline.settled")
        ClotheslineTrace.log("clothesline.openWork decoded=\(PrintImages.decodeCount - start.decoded) queries=\(state.queries - start.queries)")
    }

    /// `restoreFocus` hands the keyboard back to the app that was in front, unless the user is going somewhere else:
    /// clicking another app, opening Preview or the library.
    func hide(restoreFocus: Bool = true) {
        guard isShown else { return }
        ClotheslineTrace.log("clothesline.hide")
        isShown = false
        openWork = nil
        cancelDwell()
        panel.ignoresMouseEvents = true
        removeShownMonitors()
        model.clotheslineOpen = false
        state.retract { [weak self] in
            guard let self, !self.isShown else { return }
            self.panel.exposed = false
            ClotheslineTrace.log("clothesline.hidden")
            if let next = self.pendingScreen {
                self.pendingScreen = nil
                self.show(byPointer: self.pendingByPointer, on: next)
            } else {
                self.fitPanel(on: Self.pointerScreen())
            }
        }
        if restoreFocus, let app = previousApp, !app.isTerminated {
            app.activate()
        } else if panel.isKeyWindow {
            NSApp.windows.first { $0.title == "ShotBox" && $0.isVisible && $0.canBecomeKey }?.makeKey()
        }
        previousApp = nil
    }

    /// Full width of `screen`, top at its menubar's bottom edge (its top edge when it has no menubar), and always
    /// tall enough for the basket. Only ever called while the line is hidden: the window never moves or resizes while
    /// anything is drawn in it.
    private func fitPanel(on screen: NSScreen) {
        self.screen = screen
        state.fit(screenWidth: screen.frame.width)
        let f = frame(on: screen)
        if panel.frame != f { panel.setFrame(f, display: false) }
        host?.frame = NSRect(origin: .zero, size: f.size)
        stage?.frame = NSRect(origin: .zero, size: f.size)
    }

    private func frame(on screen: NSScreen) -> NSRect {
        let h = min(StripMetrics.panelHeight, screen.visibleFrame.height)
        return NSRect(x: screen.frame.minX, y: screen.visibleFrame.maxY - h, width: screen.frame.width, height: h)
    }

    // MARK: Pointer at the top edge

    private func cancelDwell() {
        dwell?.cancel()
        dwell = nil
        dwellScreen = nil
    }

    private static func atTopEdge(_ p: NSPoint, of screen: NSScreen) -> Bool {
        p.y >= screen.frame.maxY - 1 && p.x >= screen.frame.minX && p.x < screen.frame.maxX
    }

    /// Resting on the very top row of any screen for 0.12 s opens the line on that screen. While hidden, the panel
    /// follows the pointer to whichever screen holds it, so it is fitted before it is called. Moving away from a line
    /// the pointer opened retracts it; moving to another screen's top edge moves the line there. Button presses never
    /// open it, so dragging a window under the edge does nothing.
    private func pointerMoved() {
        let p = NSEvent.mouseLocation
        let here = Self.pointerScreen()
        if !isShown, !Self.same(here, screen), pendingScreen == nil, !state.visible { fitPanel(on: here) }
        let edge = Self.atTopEdge(p, of: here) && NSEvent.pressedMouseButtons == 0
        if isShown {
            if !Self.same(here, screen) {
                // On another screen now: once the pointer has settled there, the line goes up here and comes down
                // on that screen, sized to it. A line the pointer opened only follows to another top edge.
                if shownByPointer, !edge {
                    cancelDwell()
                    hide()
                } else {
                    armDwell(on: here)
                }
                return
            }
            // Only the part that is drawn counts: the line, and the basket when it is open.
            var live = panel.frame
            let drawn = state.lineHeight + (state.basketOpen || state.peekID != nil ? StripMetrics.basketHeight : 0)
            live.origin.y = live.maxY - drawn
            live.size.height = drawn
            if shownByPointer, !live.insetBy(dx: -40, dy: -40).contains(p) { hide() }
            // Keeping the pointer at the top edge pulls the line further down: the basket opens.
            if edge, !state.basketOpen { armDwell(on: here, basket: true) } else if !edge { cancelDwell() }
            return
        }
        if edge { armDwell(on: here) } else { cancelDwell() }
    }

    private func armDwell(on target: NSScreen, basket: Bool = false) {
        guard dwell == nil || !Self.same(dwellScreen, target) else { return }
        cancelDwell()
        dwellScreen = target
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.dwell = nil
            self.dwellScreen = nil
            let p = NSEvent.mouseLocation
            guard NSEvent.pressedMouseButtons == 0 else { return }
            if self.isShown, !Self.same(target, self.screen) {
                guard Self.same(Self.pointerScreen(), target) else { return }
                self.pendingScreen = target
                let byPointer = self.shownByPointer
                self.hide(restoreFocus: false)
                // A line the hotkey opened stays a hotkey line on the new screen: it does not retract on its own.
                self.pendingByPointer = byPointer
                return
            }
            guard Self.atTopEdge(p, of: target) else { return }
            if basket {
                if self.isShown, Self.same(target, self.screen) { self.state.setBasket(true) }
            } else if !self.isShown {
                self.show(byPointer: true, on: target)
            }
        }
        dwell = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (basket ? 0.9 : Self.dwellTime), execute: work)
    }

    // MARK: While shown

    /// Keys search and pick; Esc clears a search first, then closes. A click anywhere else closes it.
    private func installShownMonitors() {
        removeShownMonitors()
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, self.isShown, event.window === self.panel || NSApp.keyWindow === self.panel else { return event }
            return self.handleKey(event) ? nil : event
        }) { shownMonitors.append(keys) }
        // Holding ⌘ shows each print's number; ⌘1…⌘9 copy that print.
        if let flags = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            self?.state.setCommandHeld(mods == .command)
            return event
        }) { shownMonitors.append(flags) }
        if let scroll = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            self?.handleScroll(event)
            return event
        }) { shownMonitors.append(scroll) }
        if let clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            if event.window !== self?.panel { self?.hide(restoreFocus: false) }
            return event
        }) { shownMonitors.append(clicks) }
        if let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.hide(restoreFocus: false)
        }) { shownMonitors.append(outside) }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // Esc: put a peeked print back, then clear the search, then close
            if state.peekID != nil { state.peek(nil) } else if state.query.isEmpty { hide() } else { state.clearQuery() }
        case 49 where state.query.isEmpty: // Space peeks, as in Quick Look; inside a search it is just a space
            state.togglePeek()
        case 51, 117: // Delete
            state.deleteBackward()
        case 36, 76: // Return
            if let c = state.chosen {
                model.copy(c, hud: true)
                if state.line.contains(where: { $0.id == c.id }), state.peekID == nil {
                    // On the line: the print is tugged and "Copied" shows under it before the line goes up.
                    state.markCopied(c.id)
                    DispatchQueue.main.asyncAfter(deadline: .now() + LineMotion.copiedHold) { [weak self] in self?.hide() }
                } else {
                    hide()
                }
            }
        case 123: state.moveFocus(-1)
        case 124: state.moveFocus(1)
        case 125:
            state.peek(nil)
            state.setBasket(true)
        case 126: state.setBasket(false)
        default:
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods == .command, let n = event.charactersIgnoringModifiers.flatMap(Int.init), n >= 1 {
                guard let c = state.hanging(number: n) else { NSSound.beep(); return true }
                model.copy(c, hud: true)
                state.markCopied(c.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + LineMotion.copiedHold) { [weak self] in self?.hide() }
                return true
            }
            guard mods.isDisjoint(with: [.command, .control]),
                  let text = event.characters, !text.isEmpty,
                  text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 })
            else { return false }
            state.type(text)
        }
        return true
    }

    /// Pulling the line further down opens the basket; pushing it back up folds it. Inside the basket, scrolling scrolls.
    private func handleScroll(_ event: NSEvent) {
        guard event.window === panel else { return }
        let fromTop = panel.frame.height - event.locationInWindow.y
        guard fromTop < state.lineHeight else { return }
        if event.phase == .began { pull = 0 }
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return }
        // Natural scrolling reports a downward finger pull as positive; a classic wheel turned towards you as negative.
        pull += event.isDirectionInvertedFromDevice ? event.scrollingDeltaY : -event.scrollingDeltaY
        if pull > 14 {
            pull = 0
            state.setBasket(true)
        } else if pull < -14 {
            pull = 0
            state.setBasket(false)
        }
    }

    private func removeShownMonitors() {
        shownMonitors.forEach { NSEvent.removeMonitor($0) }
        shownMonitors.removeAll()
    }
}

/// A borderless panel still has to become key while shown, or Esc, typing and clicks would not reach it. Hidden, it
/// stays on screen but never takes the keyboard and keeps out of the accessibility tree.
private final class ClotheslinePanel: NSPanel {
    var exposed = false

    override var canBecomeKey: Bool { exposed }
    override func isAccessibilityElement() -> Bool { exposed }
    override func accessibilityChildren() -> [Any]? { exposed ? super.accessibilityChildren() : [] }
}
