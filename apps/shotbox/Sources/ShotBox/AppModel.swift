import AppKit
import Carbon.HIToolbox
import SwiftUI

extension Notification.Name {
    /// Asks the main view to move keyboard focus from the search field to the grid.
    static let focusGrid = Notification.Name("ShotBox.focusGrid")
}

/// Animation presets. Spring-based; Reduce Motion falls back to a short cross-fade.
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var hero: Animation { reduced ? .easeInOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.82) }
    /// Card to preview and back. Slower than `hero` so the image visibly grows and the grid blurs over ~0.5 s.
    static var open: Animation { reduced ? .easeInOut(duration: 0.2) : .spring(response: 0.6, dampingFraction: 0.9) }
    static var reflow: Animation { reduced ? .easeInOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.8) }
}

extension Capture {
    /// Grid identity. It does not change with the pin, so a pinned card moves to its new place as the same card
    /// instead of being removed and inserted, which dropped it for a frame before it landed.
    var gridKey: String { "card-\(id)" }

    /// The rect this image takes when it is aspect-fit in `box`, the way the card bay and the preview draw it.
    func imageRect(in box: CGRect) -> CGRect {
        guard width > 0, height > 0 else { return box }
        let scale = min(box.width / CGFloat(width), box.height / CGFloat(height))
        let w = CGFloat(width) * scale
        let h = CGFloat(height) * scale
        return CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }
}

/// Single source of UI state. Views read `captures` in display order: pinned first, then newest.
final class AppModel: ObservableObject {
    let engine: Engine

    /// The whole library in display order: pinned first, then newest. Searching does not touch it, so every card keeps a home slot.
    @Published private(set) var library: [Capture] = []
    /// What the grid shows and the keyboard walks: the library, narrowed by the search.
    @Published private(set) var captures: [Capture] = []
    /// While a search is shown or leaving: the ids that match. Nil when the whole library is lit.
    @Published private(set) var filterIDs: Set<Int64>?
    /// True once the matches have glided into the packed result layout.
    @Published private(set) var packed = false
    /// True while the cards that do not match are dimmed in their home slots.
    @Published private(set) var dim = false
    /// The captures just before and just after the one Esc landed on, for about two seconds: id to "Before" or "After".
    @Published private(set) var neighbourMarks: [Int64: String] = [:]
    /// Asks the grid to scroll a card to its home slot. The counter makes a repeat request count.
    @Published private(set) var revealRequest: (id: Int64, serial: Int)?
    @Published private(set) var totalCount = 0
    /// Unpinned captures the current retention removes next, oldest first. Settings shows the first few as "Next to go".
    @Published private(set) var nextToGo: [Capture] = []
    /// How many unpinned captures the current retention would remove next. Live, so it follows every capture and delete.
    @Published private(set) var nextCount = 0
    /// Captures the last committed retention change removed. Nil until a change is made this session.
    @Published private(set) var lastRemoved: Int?
    /// The newest captures, ignoring pins and search. The Clothesline hangs these.
    @Published private(set) var recent: [Capture] = []
    /// Bumps on every reload, so Settings can re-read the size on disk.
    @Published private(set) var revision = 0
    @Published var clotheslineOpen = false
    /// Whether the screenshot folder is watched. Stored; clipboard capture is always on.
    @Published var watchFolder = true {
        didSet {
            engine.watchFolderEnabled = watchFolder
            engine.store.setSetting("watch_folder", watchFolder ? "1" : "0")
        }
    }
    /// Full images older than this many days are shrunk to a compressed copy.
    @Published private(set) var shrinkDays = 30
    @Published private(set) var retention: Retention
    @Published var searchText = "" {
        didSet { if searchText != oldValue { searchChanged() } }
    }
    @Published var selectedID: Int64?
    /// The card under the pointer, if any. Only one card shows its hover buttons.
    @Published var hoveredID: Int64?
    @Published var previewID: Int64?
    /// The card the preview was opened from. Only this image morphs from its card; neighbours slide.
    @Published var heroID: Int64?
    /// True while an opened image flies back to its card. The preview stays up until it lands.
    @Published private(set) var closingPreview = false
    /// The capture that just arrived from the watch folder or pasteboard. Only it slides in from the top.
    @Published private(set) var freshID: Int64?
    /// The card whose seal note is open, if any. Esc closes it before anything else.
    @Published var sealID: Int64?
    /// Captures being deleted. They scale and fade out in place before their rows go, so neighbours close the gap after.
    @Published private(set) var departing: Set<Int64> = []
    @Published var previewForward = true
    @Published var previewBounce: CGFloat = 0
    @Published var showText = false
    @Published var toast: String?
    @Published var cardSize: Double = 180 {
        didSet { engine.store.setSetting("card_size", String(Int(cardSize))) }
    }
    @Published var paused = false {
        didSet {
            engine.paused = paused
            engine.store.setSetting("paused", paused ? "1" : "0")
        }
    }

    /// Set by the menubar label, which lives for the whole app run, so it can reopen the window.
    var openMainWindow: (() -> Void)?

    private var generation = 0
    private var searchEpoch = 0
    private var revealSerial = 0
    private var lastReload = Date.distantPast
    private var reloadPending = false
    /// False until the first library load, so the captures already there do not slide in at launch.
    private var loaded = false
    private var toastWork: DispatchWorkItem?
    private let hud = ToastHUD()
    /// Created last in init, since it reads this model.
    private(set) var clothesline: Clothesline!

    init() {
        let store: Store
        do {
            store = try Store(dataDir: Config.dataDir)
        } catch {
            fatalError("ShotBox cannot open its data folder: \(error)")
        }
        engine = Engine(store: store)
        retention = store.retention()
        paused = store.setting("paused") == "1"
        cardSize = Double(store.setting("card_size") ?? "") ?? 180
        engine.paused = paused
        watchFolder = store.setting("watch_folder") != "0"
        engine.watchFolderEnabled = watchFolder
        shrinkDays = store.shrinkDays()
        engine.onChange = { [weak self] in self?.reloadSoon() }
        engine.onDuplicate = { [weak self] id in self?.showDuplicate(id) }
        HotKey.register(keyCode: kVK_ANSI_S, id: 1) { [weak self] in self?.showMainWindow() }
        HotKey.register(keyCode: kVK_ANSI_L, id: 2) { [weak self] in self?.toggleClothesline() }
        installDeleteKey()
        installTabKey()
        installSealEscape()
        engine.applyRetention()
        clothesline = Clothesline(model: self)
        reload()
    }

    /// SwiftUI's onKeyPress(.delete) and onDeleteCommand did not receive Backspace or Forward Delete
    /// on the grid, so a local monitor reads them. It only acts when the ShotBox window is key
    /// and no text field is editing, so search-field editing is unaffected.
    private func installDeleteKey() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 51 || event.keyCode == 117 else { return event }
            guard NSApp.keyWindow?.title == "ShotBox", !(NSApp.keyWindow?.firstResponder is NSTextView) else { return event }
            guard self.previewID != nil || self.selectedID != nil else { return event }
            self.deleteCurrent()
            return nil
        }
    }

    /// Tab walks the cards in display order while the grid has the keyboard. It is taken here, before the window's own
    /// Tab handling moves focus to the search field. From the search field, Tab hands the keyboard back to the grid.
    private func installTabKey() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 48, self.previewID == nil,
                  let window = NSApp.keyWindow, window.title == "ShotBox" else { return event }
            if window.firstResponder is NSTextView {
                NotificationCenter.default.post(name: .focusGrid, object: nil)
            } else {
                self.moveSelection(event.modifierFlags.contains(.shift) ? -1 : 1)
            }
            return nil
        }
    }

    /// Esc closes an open seal note wherever focus is (the ribbon button takes focus when it is pressed).
    /// It is consumed here, so it does not also close a preview or clear the search.
    private func installSealEscape() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, self.sealID != nil else { return event }
            self.sealID = nil
            return nil
        }
    }

    // MARK: Loading

    /// Engine-driven changes (a capture arrived, OCR finished) arrive in bursts; they reload at most four times a second.
    private func reloadSoon() {
        let wait = 0.25 - Date().timeIntervalSince(lastReload)
        if wait <= 0 { reload(); return }
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.reloadPending = false
            self?.reload()
        }
    }

    /// Fetches on a background queue. Only the newest request is applied.
    func reload() {
        generation += 1
        lastReload = Date()
        let gen = generation
        let store = engine.store
        let rule = retention
        DispatchQueue.global(qos: .userInitiated).async {
            let list = store.fetch(search: "")
            let total = store.count()
            let due = store.nextToGo(rule, limit: 8)
            let dueCount = store.nextCount(rule)
            let newest = store.recent(limit: 30)
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                // A grown library means a new capture arrived; it is the one that slides in.
                // The first load is not an arrival, but a first capture into an empty library is one.
                let known = Set(self.library.map(\.id))
                let arrived = self.loaded && total > self.totalCount
                    ? list.first { !known.contains($0.id) }?.id
                    : nil
                self.loaded = true
                if let arrived { self.freshID = arrived }
                if list != self.library {
                    withAnimation(Motion.reflow) {
                        self.library = list
                        self.captures = self.narrowed(list)
                        if let filter = self.filterIDs, self.searchText.isEmpty == false {
                            self.filterIDs = filter.union(self.captures.map(\.id))
                        }
                    }
                }
                if total != self.totalCount { self.totalCount = total }
                if dueCount != self.nextCount { self.nextCount = dueCount }
                let nextIDs = due.map(\.id)
                if nextIDs != self.nextToGo.map(\.id) { self.nextToGo = due }
                if newest != self.recent { self.recent = newest }
                self.revision += 1
                if let arrived {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        if self.freshID == arrived { self.freshID = nil }
                    }
                }
                if let id = self.previewID, !self.captures.contains(where: { $0.id == id }) { self.previewID = nil }
                if let id = self.selectedID, !self.captures.contains(where: { $0.id == id }) { self.selectedID = nil }
            }
        }
    }

    // MARK: Search

    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Whether a capture matches a query: its name, recognised text, address, or (for clipboard captures) the app.
    static func matches(_ c: Capture, _ query: String) -> Bool {
        if c.name.localizedCaseInsensitiveContains(query) || c.ocrText.localizedCaseInsensitiveContains(query) { return true }
        if c.source == "pasteboard", let app = c.app, app.localizedCaseInsensitiveContains(query) { return true }
        let squeezed = query.filter { !$0.isWhitespace }
        return c.address.localizedCaseInsensitiveContains(query) || c.addressCompact.localizedCaseInsensitiveContains(query)
            || (!squeezed.isEmpty && c.address.filter { !$0.isWhitespace }.localizedCaseInsensitiveContains(squeezed))
    }

    private func narrowed(_ list: [Capture]) -> [Capture] {
        let q = query
        return q.isEmpty ? list : list.filter { Self.matches($0, q) }
    }

    /// Narrowing: the matches light up in their own slots while the rest dim, then glide into the packed layout.
    /// Clearing plays it backwards. The list the keyboard walks changes at once; only the picture is staged.
    private func searchChanged() {
        searchEpoch += 1
        let epoch = searchEpoch
        let q = query
        let list = narrowed(library)
        let wasShown = filterIDs != nil
        captures = list
        if let id = selectedID, !list.contains(where: { $0.id == id }) { selectedID = nil }
        if let id = previewID, !list.contains(where: { $0.id == id }) { previewID = nil }
        if q.isEmpty {
            guard wasShown else { return }
            dim = true
            withAnimation(Motion.reflow) { packed = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.searchEpoch == epoch else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    self.filterIDs = nil
                    self.dim = false
                }
            }
            return
        }
        let ids = Set(list.map(\.id))
        if packed {
            withAnimation(Motion.reflow) { filterIDs = ids }
        } else {
            filterIDs = ids
            withAnimation(.easeOut(duration: 0.15)) { dim = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.searchEpoch == epoch else { return }
                withAnimation(Motion.reflow) { self.packed = true }
            }
        }
    }

    /// Esc on a search: clears it, keeps the selected card, scrolls the full grid to it and marks its neighbours in time.
    func escapeSearch() {
        let keep = selectedID
        searchText = ""
        guard let id = keep, let c = library.first(where: { $0.id == id }) else { return }
        selectedID = id
        revealSerial += 1
        revealRequest = (id, revealSerial)
        let byTime = library.sorted { $0.created > $1.created }
        guard let i = byTime.firstIndex(where: { $0.id == c.id }) else { return }
        var marks: [Int64: String] = [:]
        if i > 0 { marks[byTime[i - 1].id] = "After" }
        if i + 1 < byTime.count { marks[byTime[i + 1].id] = "Before" }
        withAnimation(Motion.reflow) { neighbourMarks = marks }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            withAnimation(Motion.reflow) { self?.neighbourMarks = [:] }
        }
    }

    var focusedCapture: Capture? {
        captures.first { $0.id == (previewID ?? selectedID) }
    }

    // MARK: Actions

    /// `hud` puts the confirmation outside the window, for copies made from the Clothesline.
    func copy(_ c: Capture, hud: Bool = false) {
        showToast("Copied", hud: hud)
        engine.copyToPasteboard(c)
        engine.store.recordEvent(c.id, "copied")
        reload()
    }

    /// Copies recognised text or an identifier chip. Plain text, so no capture is made.
    func copyText(_ text: String, of id: Int64, kind: String = "text-copied") {
        engine.copyText(text)
        engine.store.recordEvent(id, kind)
        reload()
        showToast("Copied")
    }

    func copyFocused() {
        if let c = focusedCapture { copy(c) }
    }

    func openInPreview(_ c: Capture) {
        engine.openInPreview(c)
        engine.store.recordEvent(c.id, "opened")
        reload()
    }

    func reveal(_ c: Capture) {
        engine.reveal(c)
    }

    func togglePin(_ c: Capture) {
        engine.setPinned(c.id, !c.pinned)
        reload()
    }

    func togglePinFocused() {
        if let c = focusedCapture { togglePin(c) }
    }

    func delete(_ ids: [Int64]) {
        guard !ids.isEmpty else { return }
        withAnimation(.easeIn(duration: 0.16)) { departing.formUnion(ids) }
        // The cards go once they have shrunk away; deleting at once would let neighbours pass through them.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) { [weak self] in
            guard let self else { return }
            let gone = Set(ids)
            withAnimation(Motion.reflow) {
                self.library.removeAll { gone.contains($0.id) }
                self.captures.removeAll { gone.contains($0.id) }
                self.totalCount = self.library.count
            }
            self.departing.subtract(ids)
            DispatchQueue.global(qos: .userInitiated).async {
                self.engine.delete(ids)
                DispatchQueue.main.async { self.reload() }
            }
        }
    }

    /// Deletes the previewed or selected capture. In preview, moves to a neighbour or closes.
    func deleteCurrent() {
        guard let id = previewID ?? selectedID, let idx = captures.firstIndex(where: { $0.id == id }) else { return }
        let neighbour: Int64? = captures.indices.contains(idx + 1)
            ? captures[idx + 1].id
            : (idx > 0 ? captures[idx - 1].id : nil)
        withAnimation(Motion.hero) {
            if previewID != nil { previewID = neighbour }
            selectedID = neighbour
        }
        delete([id])
    }

    /// Shows in the main window when it is on screen, otherwise in the floating HUD so the feedback is never lost.
    func showToast(_ text: String, hud useHUD: Bool = false, hold: Double = 1.5) {
        let mainVisible = NSApp.windows.contains { $0.title == "ShotBox" && $0.isVisible }
        if useHUD || !mainVisible {
            hud.flash(text)
            return
        }
        toastWork?.cancel()
        withAnimation(Motion.reflow) { toast = text }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(Motion.reflow) { self?.toast = nil }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: work)
    }

    /// The incoming image is already in the library. Select that card and say so; nothing is stored.
    private func showDuplicate(_ id: Int64) {
        selectedID = id
        showToast("Already saved", hold: 3)
    }

    // MARK: Clothesline

    func toggleClothesline() {
        clothesline.toggle()
    }

    func hideClothesline() {
        clothesline.hide()
    }

    // MARK: Keyboard selection

    func moveSelection(_ delta: Int) {
        guard !captures.isEmpty else { return }
        guard let id = selectedID, let idx = captures.firstIndex(where: { $0.id == id }) else {
            selectedID = captures.first?.id
            return
        }
        selectedID = captures[min(max(idx + delta, 0), captures.count - 1)].id
    }

    func activateSelection() {
        if selectedID == nil { selectedID = captures.first?.id }
        if let id = selectedID { openPreview(id) }
    }

    // MARK: Preview

    func openPreview(_ id: Int64) {
        // Every state change for the open goes in one animated transaction, so the image's morph and the blur run together.
        withAnimation(Motion.open) {
            selectedID = id
            previewID = id
            heroID = id
        }
    }

    /// A card opened from the grid flies back into its bay; any other close is at once.
    func closePreview() {
        guard previewID != nil, !closingPreview else { return }
        guard heroID == previewID else {
            endPreview()
            return
        }
        withAnimation(Motion.open) { closingPreview = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.endPreview()
        }
    }

    private func endPreview() {
        withAnimation(Motion.open) {
            previewID = nil
            showText = false
        }
        closingPreview = false
    }

    func toggleText() {
        withAnimation(Motion.reflow) { showText.toggle() }
    }

    /// Moves to a neighbour in display order. At either end the image nudges and springs back.
    func step(_ delta: Int) {
        guard !closingPreview, let id = previewID, let idx = captures.firstIndex(where: { $0.id == id }) else { return }
        let target = idx + delta
        guard captures.indices.contains(target) else {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.45)) { previewBounce = CGFloat(-delta) * 14 }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.5).delay(0.15)) { previewBounce = 0 }
            return
        }
        previewForward = delta > 0
        withAnimation(Motion.hero) {
            previewID = captures[target].id
            selectedID = previewID
            heroID = nil
        }
    }

    // MARK: Windows and settings

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == "ShotBox" && $0.canBecomeMain }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }

    /// Shrink threshold, applied at once. Shrinking runs in the same pass as retention.
    func setShrinkDays(_ days: Int) {
        shrinkDays = max(1, days)
        engine.store.setSetting("shrink_days", String(shrinkDays))
        engine.applyRetention()
    }

    /// How many unpinned captures a rule would remove now. Settings asks this before a rule is applied.
    func wouldRemove(_ r: Retention) -> Int {
        engine.store.overflow(r).count
    }

    /// The captures a typed rule would remove, oldest first, for Settings' preview before Apply.
    func draftCandidates(_ r: Retention) -> [Capture] {
        engine.store.overflowCaptures(r, limit: 8)
    }

    /// Applies the rule. The removal count and "next to go" follow in the reload it triggers.
    func setRetention(_ r: Retention) {
        retention = r
        engine.store.saveRetention(r)
        engine.applyRetention { [weak self] removed in
            self?.lastRemoved = removed
        }
    }
}
