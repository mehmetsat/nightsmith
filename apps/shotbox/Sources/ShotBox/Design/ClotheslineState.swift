import Combine
import SwiftUI

/// What hangs where. The line is "now": the newest few captures, pinned or not, newest first. The basket is "the
/// past": the rest of the library, newest first. Typing filters both; prints that stop matching unpeg and drop out of
/// view, the rest slide together. Pinned prints hang from a steel clip.
///
/// Everything here is ready before the line is called: the library is fetched and split as captures arrive, and the
/// prints' images are decoded at the size they hang, and the line's layers are built (see `LineStage`). Opening only
/// adds springs to those layers.
final class ClotheslineState: ObservableObject {
    /// At most this many prints hang at once; fewer on a narrow screen (see `fit(screenWidth:)`).
    static let maxOnLine = 6
    static let basketLimit = 400

    /// Whether the line is drawn at all: from the moment it is called until it has fully retracted.
    @Published private(set) var visible = false
    /// The line is down (or on its way down). The drop, rope stretch and swing all key off this.
    @Published private(set) var dropped = false
    /// The line is on its way up.
    @Published private(set) var retracting = false
    @Published private(set) var basketOpen = false
    @Published private(set) var query = ""
    /// Prints on the line, in order, after the search.
    @Published private(set) var line: [Capture] = []
    /// Where each print on the line hangs at rest, on the current screen.
    @Published private(set) var layout = LineLayout.empty
    /// Prints in the basket, after the search.
    @Published private(set) var basket: [Capture] = []
    /// Older captures that are not on the line, before the search.
    @Published private(set) var olderCount = 0
    @Published var hoveredID: Int64?
    @Published var focusedID: Int64?
    /// The print just copied: "Copied" shows under it until the line tucks away.
    @Published private(set) var copiedID: Int64?
    /// True for the 120 ms the copied print flashes.
    @Published private(set) var flashing = false
    /// The print pulled towards the viewer at full size (Space): readable without Preview.
    @Published private(set) var peekID: Int64?
    /// ⌘ is down: each print shows the number that copies it (⌘1 the newest).
    @Published private(set) var commandHeld = false
    /// The print being dragged off the line into another app.
    @Published var takenID: Int64?
    /// Whether the next print to appear comes in from the left (a new capture) or from above (a search was cleared).
    @Published private(set) var arrivingFromLeft = false
    /// Captures that landed since they were last looked at: their peg wears an accent dot until hovered or copied.
    @Published private(set) var unseen: Set<Int64> = []

    /// A click on the clear part of the panel, away from any print, tucks the line away.
    var onBackgroundTap: (() -> Void)?
    /// The layers that draw the line. Every layout change is handed to it; hover, focus and the rest it picks up
    /// on its own.
    weak var stage: LineStage? {
        didSet { stage?.apply(layout, animated: false, fromLeft: false) }
    }

    let store: Store
    private var all: [Capture] = []
    private var known: Set<Int64>?
    private var matches: Set<Int64>?
    private var capacity = maxOnLine
    /// How many prints lie side by side in the basket.
    private(set) var basketColumns = 6
    /// The screen's width; the line spans it.
    private(set) var viewport: CGFloat = 1440
    /// The height of the line's part of the window on this screen: rope, prints and the room under them.
    @Published private(set) var lineHeight: CGFloat = RopeCurve.lineHeight(width: 1440)
    private var fittedWidth: CGFloat?
    /// A new capture held back while hidden, so it can be pegged on in front of the user after the drop.
    private var held: Int64?
    private var lastSeenNewest: Int64?
    private var autoBasket = false
    private var searchGeneration = 0
    private var motionGeneration = 0
    private var revisionSub: AnyCancellable?
    private var marksSub: AnyCancellable?
    /// Library fetches made, for the open-path trace.
    private(set) var queries = 0

    init(model: AppModel) {
        store = model.engine.store
        revisionSub = model.$revision.sink { [weak self] _ in
            DispatchQueue.main.async { self?.reload() }
        }
        marksSub = objectWillChange.sink { [weak self] _ in self?.stage?.setNeedsMarks() }
    }

    var newestUnpinned: Capture? { all.first { !$0.pinned } }

    func matchesSearch(_ id: Int64) -> Bool { matches?.contains(id) ?? true }

    /// Prints sized for this screen, and as many as hang comfortably across its middle, between 2 and 6. Called
    /// while hidden, whenever the pointer moves to another screen, so the line is laid out and its pictures decoded
    /// for that screen before it is called.
    func fit(screenWidth: CGFloat) {
        guard screenWidth != fittedWidth else { return }
        fittedWidth = screenWidth
        viewport = screenWidth
        PrintMetrics.fit(screenWidth: screenWidth)
        lineHeight = RopeCurve.lineHeight(width: screenWidth)
        let n = Int((LineLayout.room(screenWidth) + LineLayout.gap) / (PrintMetrics.typicalWidth + LineLayout.gap))
        capacity = min(max(n, 2), Self.maxOnLine)
        basketColumns = (3...7).last { BasketView.width(columns: $0) <= screenWidth - 2 * LineLayout.margin } ?? 3
        arrange(animated: false)
        prewarm()
    }

    // MARK: Loading

    func reload() {
        let store = store
        let query = query
        queries += query.isEmpty ? 1 : 2
        DispatchQueue.global(qos: .userInitiated).async {
            let everything = store.fetch(search: "")
            let hits = query.isEmpty ? nil : Set(store.fetch(search: query).map(\.id))
            DispatchQueue.main.async { self.apply(everything, hits, for: query) }
        }
    }

    private func apply(_ everything: [Capture], _ hits: Set<Int64>?, for query: String) {
        guard query == self.query else { return }
        let ids = Set(everything.map(\.id))
        if let known {
            unseen.formUnion(ids.subtracting(known))
        } else if let newest = everything.first(where: { !$0.pinned }) {
            // First load: the newest capture is the one the user has not seen on the line yet.
            unseen = [newest.id]
        }
        unseen.formIntersection(ids)
        let wasKnown = known ?? []
        known = ids
        all = everything.sorted { $0.created > $1.created }
        matches = hits
        let newest = all.first?.id
        // A capture that arrives while the line is down is pegged on in front of the user.
        if visible, !retracting, !wasKnown.isEmpty, let newest, !wasKnown.contains(newest) {
            lastSeenNewest = newest
            arrivingFromLeft = true
            unseen.insert(newest)
            arrange(animated: true)
            stage?.glow(newest)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.arrivingFromLeft = false }
        } else {
            arrange(animated: visible)
        }
        prewarm()
    }

    /// Decodes every print that could hang on the line, at the size it hangs, off the main thread, while the line
    /// is hidden. The drop then draws from memory.
    private func prewarm() {
        let store = store
        for c in all.prefix(Self.maxOnLine) {
            Task.detached(priority: .utility) { _ = await PrintImages.load(c, store: store) }
        }
    }

    /// Splits the library into the line and the basket, then applies the search. Newest first, pinned or not.
    private func arrange(animated: Bool) {
        let candidates = all.filter { $0.id != held }
        var hung = Array(candidates.prefix(capacity))
        let room = LineLayout.room(viewport)
        while hung.count > 1, LineLayout.span(hung) > room { hung.removeLast() }
        let hungIDs = Set(hung.map(\.id))
        let older = all.filter { !hungIDs.contains($0.id) && $0.id != held }
        let next: [Capture]
        let baskets: [Capture]
        if let matches {
            next = hung.filter { matches.contains($0.id) }
            baskets = Array(older.filter { matches.contains($0.id) }.prefix(Self.basketLimit))
        } else {
            next = hung
            baskets = Array(older.prefix(Self.basketLimit))
        }
        let layout = LineLayout(next, width: viewport)
        let update = {
            self.olderCount = older.count
            self.line = next
            self.layout = layout
            self.basket = baskets
            if let id = self.focusedID, !next.contains(where: { $0.id == id }) { self.focusedID = nil }
        }
        if animated {
            withAnimation(LineMotion.reflow, update)
        } else {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t, update)
        }
        stage?.apply(layout, animated: animated, fromLeft: arrivingFromLeft)
    }

    /// Whether the grabber for the basket hangs under the line.
    var hasBasketPull: Bool { olderCount > 0 || basketOpen }

    // MARK: Showing

    /// The line comes down. Everything it shows is already built; this resets the transient state without animation,
    /// makes the line visible and starts the drop, outward from `pointerX`. `settled` runs once the last print is
    /// within 2 % of rest.
    func drop(pointerX: CGFloat?, settled: @escaping () -> Void) {
        motionGeneration += 1
        let gen = motionGeneration
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            query = ""
            matches = nil
            focusedID = nil
            hoveredID = nil
            copiedID = nil
            flashing = false
            peekID = nil
            commandHeld = false
            takenID = nil
            basketOpen = false
            arrivingFromLeft = false
            retracting = false
            dropped = false
            visible = true
        }
        autoBasket = false
        // A capture taken since the line was last down is held back and pegged on after the drop.
        if let newest = all.first?.id, let seen = lastSeenNewest, newest != seen, line.contains(where: { $0.id == newest }) {
            held = newest
            arrange(animated: false)
        }
        lastSeenNewest = all.first?.id
        dropped = true
        let settle = stage?.drop(pointerX: pointerX, fresh: unseen) ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
            guard gen == self.motionGeneration else { return }
            settled()
        }
        if held != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + settle + 0.05) { self.pegHeld() }
        }
    }

    /// The held capture is carried in from the left and pegged on; the others move along on the same spring.
    private func pegHeld() {
        guard let id = held, visible, dropped else { return }
        held = nil
        arrivingFromLeft = true
        unseen.insert(id)
        arrange(animated: true)
        stage?.glow(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.arrivingFromLeft = false }
    }

    /// The line goes up: 170 ms ease-in, or a 0.2 s fade under Reduce Motion. `gone` runs once it is fully clear.
    func retract(gone: @escaping () -> Void) {
        guard visible else { gone(); return }
        motionGeneration += 1
        let gen = motionGeneration
        withAnimation(.timingCurve(0.4, 0, 1, 1, duration: LineMotion.retractDuration)) {
            dropped = false
            retracting = true
            basketOpen = false
            peekID = nil
        }
        let finish = {
            guard gen == self.motionGeneration else { return }
            self.didHide()
            gone()
        }
        if let stage { stage.retract(gone: finish) } else { finish() }
    }

    /// After the line has gone: forget the search, so the next drop starts clean. The tree stays built.
    private func didHide() {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            visible = false
            retracting = false
            query = ""
            matches = nil
            copiedID = nil
            flashing = false
            commandHeld = false
            takenID = nil
            hoveredID = nil
            focusedID = nil
        }
        held = nil
        arrange(animated: false)
    }

    // MARK: Peek

    /// Pulls a print forward at full size, hanging from the same spot on the rope. The basket folds away under it.
    func peek(_ id: Int64?) {
        guard id != peekID else { return }
        if id != nil { setBasket(false) }
        withAnimation(LineMotion.peek) { peekID = id }
        if let id { unseen.remove(id) }
    }

    /// Space: peek at the focused print, else the one under the pointer, else the newest; again to put it back.
    func togglePeek() {
        if peekID != nil { peek(nil); return }
        peek(focusedID ?? hoveredID ?? line.first?.id)
    }

    var peeked: Capture? { line.first { $0.id == peekID } }

    // MARK: ⌘-numbers

    func setCommandHeld(_ down: Bool) {
        guard down != commandHeld else { return }
        withAnimation(.easeOut(duration: down ? 0.14 : 0.1)) { commandHeld = down }
    }

    /// ⌘1 is the newest print on the line, ⌘2 the next, and so on.
    func hanging(number n: Int) -> Capture? {
        n >= 1 && n <= line.count ? line[n - 1] : nil
    }

    func number(of id: Int64) -> Int? {
        line.firstIndex { $0.id == id }.map { $0 + 1 }
    }

    // MARK: Copying

    /// The print is tugged down off its pegs and springs back, flashes for 120 ms, and "Copied" shows under it.
    func markCopied(_ id: Int64) {
        unseen.remove(id)
        stage?.tug(id)
        withAnimation(.easeOut(duration: 0.06)) {
            copiedID = id
            flashing = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + LineMotion.flash) {
            withAnimation(.easeOut(duration: 0.18)) { self.flashing = false }
        }
    }

    // MARK: Basket

    func setBasket(_ open: Bool) {
        guard open != basketOpen else { return }
        withAnimation(LineMotion.basket) { basketOpen = open }
    }

    // MARK: Search

    func type(_ text: String) {
        setQuery(query + text)
    }

    func deleteBackward() {
        guard !query.isEmpty else { return }
        setQuery(String(query.dropLast()))
    }

    func clearQuery() {
        setQuery("")
    }

    private func setQuery(_ q: String) {
        arrivingFromLeft = false
        peek(nil)
        withAnimation(.easeOut(duration: 0.15)) { query = q }
        // Searching reaches the whole library, so the basket opens with it and folds away again when the search ends.
        if !q.isEmpty, !basketOpen {
            autoBasket = true
            setBasket(true)
        } else if q.isEmpty, autoBasket {
            autoBasket = false
            setBasket(false)
        }
        guard !q.isEmpty else {
            matches = nil
            arrange(animated: true)
            return
        }
        searchGeneration += 1
        let gen = searchGeneration
        let store = store
        queries += 1
        DispatchQueue.global(qos: .userInitiated).async {
            let hits = Set(store.fetch(search: q).map(\.id))
            DispatchQueue.main.async {
                guard gen == self.searchGeneration, q == self.query else { return }
                self.matches = hits
                self.arrange(animated: true)
                self.focusedID = self.line.first?.id
            }
        }
    }

    // MARK: Keyboard focus and hover

    func moveFocus(_ delta: Int) {
        guard !line.isEmpty else { return }
        let idx = line.firstIndex { $0.id == focusedID }.map { $0 + delta } ?? (delta > 0 ? 0 : line.count - 1)
        let id = line[min(max(idx, 0), line.count - 1)].id
        withAnimation(LineMotion.lift) { focusedID = id }
        if peekID != nil { peek(id) }
    }

    /// The capture Return copies: the peeked or focused print, else the first on the line, else the first in the basket.
    var chosen: Capture? {
        peeked ?? line.first { $0.id == focusedID } ?? line.first ?? basket.first
    }

    func isLifted(_ id: Int64) -> Bool {
        hoveredID == id || focusedID == id
    }

    func hover(_ id: Int64, _ inside: Bool) {
        // A drag that was let go over nothing comes back: the pointer is on the line again.
        if inside, takenID != nil { takenID = nil }
        withAnimation(LineMotion.lift) {
            if inside {
                hoveredID = id
                unseen.remove(id)
            } else if hoveredID == id {
                hoveredID = nil
            }
        }
    }
}
