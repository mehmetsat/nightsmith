import AppKit
import SwiftUI

/// The main window: toolbar, thumbnail grid, empty and no-results states, and the full preview overlay.
@available(macOS 15, *)
struct MainView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @FocusState private var gridFocused: Bool
    @FocusState private var searchFocused: Bool
    @State private var gridWidth: CGFloat = 900
    @State private var gridHeight: CGFloat = 600
    /// Which 100 pt band of the content the scroll position is in. Only a band change redraws the visible window.
    @State private var scrollBand = 0
    @State private var scrollPos = ScrollPosition(edge: .top)
    /// Where the scroll view sits in the window and how far it is scrolled, for the open image's start rect.
    @State private var scrollBox = ScrollBox()

    private var columns: Int { GridLayout.columns(width: gridWidth, cardSize: model.cardSize) }

    private var trimmedQuery: String { model.searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var homePlan: GridPlan {
        GridLayout.plan(model.library, width: gridWidth, cardSize: model.cardSize, query: "")
    }

    private var packedPlan: GridPlan? {
        model.packed ? GridLayout.plan(model.captures, width: gridWidth, cardSize: model.cardSize, query: trimmedQuery) : nil
    }

    /// The plan the cards are heading for: the packed results while a search is shown, else every card at home.
    private var activePlan: GridPlan { packedPlan ?? homePlan }

    private func target(_ id: Int64, home: GridPlan, packed: GridPlan?) -> CGRect? {
        packed?.slots[id] ?? home.slots[id]
    }

    var body: some View {
        ZStack {
            Theme.sheet.ignoresSafeArea()
            Group {
                if model.captures.isEmpty {
                    emptyOrNoResults.transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    grid.transition(.opacity)
                }
            }
            // A modest blur keeps the grid's card shapes readable behind the preview. It animates with the open spring.
            .blur(radius: model.previewID == nil ? 0 : 5)
            .allowsHitTesting(model.previewID == nil)

            // Fades on its own, so the image's morph from its card is not blended with a fade of the whole preview.
            Rectangle()
                .fill(Theme.sheet.opacity(0.4))
                .opacity(model.previewID == nil ? 0 : 1)
                .contentShape(Rectangle())
                .onTapGesture { model.closePreview() }
                .allowsHitTesting(model.previewID != nil)
                .accessibilityIdentifier("previewBackdrop")

            if let id = model.previewID, let capture = model.captures.first(where: { $0.id == id }) {
                // No transition on the preview as a whole: the image morphs from its bay, and PreviewView fades its own chrome.
                PreviewView(capture: capture, store: model.engine.store, openingRect: openingRect)
                    .transition(.identity)
            }

            toast
        }
        .coordinateSpace(name: "mainSpace")
        .preferredColorScheme(Theme.scheme)
        .tint(Theme.select)
        .frame(minWidth: 640, minHeight: 480)
        .toolbar { toolbarContent }
        .focusable()
        .focused($gridFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { navigate(-1) }
        .onKeyPress(.rightArrow) { navigate(1) }
        .onKeyPress(.upArrow) {
            if model.previewID == nil { moveRow(-1) }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if model.previewID == nil { moveRow(1) }
            return .handled
        }
        .onKeyPress(.return) {
            model.activateSelection()
            return .handled
        }
        .onKeyPress(.space) {
            model.activateSelection()
            return .handled
        }
        .onKeyPress(.escape) { escape() }
        .onKeyPress(keys: ["c", "f", "p"]) { press in
            guard press.modifiers == .command else { return .ignored }
            switch press.characters {
            case "c": model.copyFocused()
            case "f": focusSearch()
            default: model.togglePinFocused()
            }
            return .handled
        }
        .onAppear { gridFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .focusGrid)) { _ in focusGrid() }
        .onChange(of: model.previewID) { _, new in
            if new == nil { gridFocused = true }
        }
    }

    /// Where the open image starts: its card's bay, when the preview was opened from the grid.
    private var openingRect: CGRect? {
        guard let id = model.previewID, model.heroID == id,
              let capture = model.captures.first(where: { $0.id == id }),
              let slot = activePlan.slots[id] else { return nil }
        let bay = CGRect(x: slot.minX + 8 + scrollBox.origin.x,
                         y: slot.minY + 8 - scrollBox.y + scrollBox.origin.y,
                         width: slot.width - 16, height: GridLayout.bayHeight(model.cardSize))
        return capture.imageRect(in: bay)
    }

    // MARK: Keyboard

    private func navigate(_ delta: Int) -> KeyPress.Result {
        if model.previewID != nil {
            model.step(delta)
        } else {
            model.moveSelection(delta)
        }
        return .handled
    }

    /// Up and Down move to the card in the row above or below, in the same column, as the grid is laid out.
    private func moveRow(_ delta: Int) {
        let plan = activePlan
        guard let id = model.selectedID, let at = plan.cell[id] else {
            model.moveSelection(0)
            return
        }
        var row = at.row + delta
        while plan.rows.indices.contains(row), plan.rows[row].isEmpty { row += delta }
        guard plan.rows.indices.contains(row) else { return }
        let ids = plan.rows[row]
        model.selectedID = ids[min(at.col, ids.count - 1)]
    }

    /// SwiftUI focus does not reach a TextField hosted in the window toolbar, so the field becomes the
    /// window's first responder directly. It is found by its placeholder.
    private func focusSearch() {
        searchFocused = true
        guard let window = NSApp.keyWindow, let root = window.contentView?.superview,
              let field = Self.searchField(in: root) else { return }
        window.makeFirstResponder(field)
    }

    /// Moves keyboard focus from the search field to the grid and selects the first card if none is selected.
    private func focusGrid() {
        // The search field's editor is an AppKit text view, which SwiftUI focus does not always hand back on its own.
        if let window = NSApp.keyWindow, window.firstResponder is NSTextView {
            window.makeFirstResponder(window.contentView)
        }
        searchFocused = false
        model.moveSelection(0)
        // The grid's focus flag may already read true, and setting it again does nothing. Clear it, then set it on the next pass.
        gridFocused = false
        DispatchQueue.main.async { gridFocused = true }
    }

    private static func searchField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.placeholderString == "Search filename or text" { return field }
        for sub in view.subviews {
            if let field = searchField(in: sub) { return field }
        }
        return nil
    }

    private func escape() -> KeyPress.Result {
        if model.sealID != nil {
            model.sealID = nil
        } else if model.previewID != nil {
            model.closePreview()
        } else if !model.searchText.isEmpty {
            model.escapeSearch()
        }
        return .handled
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search filename or text", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onKeyPress(.escape) {
                        guard !model.searchText.isEmpty else { return .ignored }
                        model.escapeSearch()
                        return .handled
                    }
                    // Down and Return leave the field for the grid, so the results can be walked from the keyboard.
                    .onKeyPress(keys: [.downArrow, .return]) { _ in
                        focusGrid()
                        return .handled
                    }
                    .accessibilityIdentifier("searchField")
                if !trimmedQuery.isEmpty {
                    Text(verbatim: "\(model.captures.count) of \(model.library.count)")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.meta)
                        .fixedSize()
                        .accessibilityIdentifier("searchCount")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(width: 260)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.hairline, lineWidth: 1))
        }
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2")
                    .foregroundStyle(.secondary)
                SizeTrack(value: $model.cardSize, range: 120...320)
                    .frame(width: 90, height: 20)
                    .accessibilityIdentifier("sizeSlider")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings")
            .accessibilityIdentifier("settingsButton")
        }
    }

    // MARK: Grid

    private var grid: some View {
        // The width comes from the grid's own proposed size, so the column count follows the window.
        GeometryReader { geo in
            let home = homePlan
            let packedNow = packedPlan
            let active = packedNow ?? home
            let window = visibleWindow(height: geo.size.height)
            let listed = Set(model.captures.map(\.id))
            let cards = model.library.filter { c in
                guard let r = target(c.id, home: home, packed: packedNow) else { return false }
                return r.maxY >= window.lowerBound && r.minY <= window.upperBound
            }
            let _ = scrollBox.origin = geo.frame(in: .named("mainSpace")).origin
            ScrollView {
                ZStack(alignment: .topLeading) {
                    if let header = active.header {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Pinned · \(active.pinnedCount)")
                                .sectionLabel()
                            Line()
                                .stroke(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                .frame(height: 1)
                        }
                        .frame(width: header.width, alignment: .leading)
                        .offset(x: header.minX, y: header.minY + 6)
                        .accessibilityIdentifier("pinnedHeader")
                    }
                    ForEach(cards) { c in
                        if let slot = target(c.id, home: home, packed: packedNow) {
                            card(c, slot: slot, listed: listed.contains(c.id))
                        }
                    }
                }
                .frame(width: geo.size.width, height: active.height, alignment: .topLeading)
                .animation(nil, value: active.height)
            }
            .scrollPosition($scrollPos)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                scrollBox.y = y
                let band = Int(max(0, y) / 100)
                if band != scrollBand { scrollBand = band }
            }
            // Leaving the grid for the toolbar or the edge drops the hover, so no card keeps its buttons.
            .onHover { inside in
                if !inside { model.hoveredID = nil }
            }
            .onAppear {
                gridWidth = geo.size.width
                gridHeight = geo.size.height
            }
            .onChange(of: geo.size.width) { _, width in gridWidth = width }
            .onChange(of: geo.size.height) { _, h in gridHeight = h }
            // No scroll while the preview is open: a layout pass during the morph cuts it short.
            .onChange(of: model.selectedID) { _, id in
                if let id, model.previewID == nil { reveal(id, centred: false) }
            }
            .onChange(of: model.previewID) { _, id in
                if id == nil, let sel = model.selectedID { reveal(sel, centred: false) }
            }
            .onChange(of: model.revealRequest?.serial) { _, _ in
                // One turn later, so the scroll view has taken the full grid's height before it is asked to scroll into it.
                if let id = model.revealRequest?.id {
                    DispatchQueue.main.async { reveal(id, centred: true) }
                }
            }
        }
    }

    /// The content rows worth drawing: the viewport and half a screen either side.
    private func visibleWindow(height: CGFloat) -> ClosedRange<CGFloat> {
        let top = CGFloat(scrollBand) * 100
        let margin = max(300, height * 0.6)
        return (top - margin)...(top + 100 + height + margin)
    }

    /// Scrolls a card into view; from Esc on a search it is centred in the full grid.
    private func reveal(_ id: Int64, centred: Bool) {
        guard let slot = (centred ? homePlan : activePlan).slots[id] else { return }
        let top = scrollBox.y
        let height = gridHeight
        let contentHeight = (centred ? homePlan : activePlan).height
        let y: CGFloat
        if centred {
            y = min(max(0, slot.midY - height / 2), max(0, contentHeight - height))
        } else if slot.minY < top + 8 {
            y = max(0, slot.minY - 8)
        } else if slot.maxY > top + height - 8 {
            y = max(0, slot.maxY - height + 8)
        } else {
            return
        }
        // Landing on a card from far away jumps there; sliding through hundreds of rows would only show empty cells.
        if centred {
            scrollPos.scrollTo(y: y)
        } else {
            withAnimation(.easeOut(duration: 0.25)) { scrollPos.scrollTo(y: y) }
        }
    }

    private func card(_ c: Capture, slot: CGRect, listed: Bool) -> some View {
        let lit = model.filterIDs.map { $0.contains(c.id) } ?? true
        let dimmed: Double = lit ? 1 : (model.packed ? 0 : (model.dim ? 0.25 : 1))
        return CardSlot(
            target: slot,
            geometryKey: "\(columns)-\(Int(model.cardSize))-\(Int(gridWidth))",
            glides: model.filterIDs != nil,
            enters: model.freshID == c.id,
            opacity: dimmed
        ) {
            CardView(
                model: model,
                capture: c,
                isSelected: model.selectedID == c.id,
                hovering: model.hoveredID == c.id,
                departing: model.departing.contains(c.id),
                previewing: model.previewID == c.id,
                sealShown: model.sealID == c.id,
                query: trimmedQuery,
                cardSize: model.cardSize,
                mark: model.neighbourMarks[c.id]
            ) {
                gridFocused = true
            }
            .equatable()
        }
        .accessibilityHidden(!listed)
        .allowsHitTesting(listed && lit)
    }

    // MARK: Empty states

    @ViewBuilder
    private var emptyOrNoResults: some View {
        if model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            VStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Theme.hairline, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    RegistrationTicks(length: 10).padding(6)
                    Text("Waiting for a screenshot")
                        .font(Theme.mono(11))
                        .tracking(1.2)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.meta)
                }
                .frame(width: 280, height: 150)
                Text("No screenshots yet")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink.opacity(0.9))
                Text("Copy a screenshot to the clipboard, or take one. It appears here on its own.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.meta)
                VStack(alignment: .leading, spacing: 8) {
                    shortcutRow("Copy a screenshot to the clipboard", ["⌘", "⌃", "⇧", "4"])
                    shortcutRow("Take a screenshot", ["⌘", "⇧", "3"])
                    shortcutRow("Bring ShotBox forward from any app", ["⌃", "⌥", "⌘", "S"])
                    shortcutRow("Open the Clothesline, a strip of your newest captures", ["⌃", "⌥", "⌘", "L"])
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("emptyState")
        } else {
            VStack(spacing: 10) {
                Text("No captures match \"\(model.searchText)\"")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink.opacity(0.9))
                    .accessibilityIdentifier("noResults")
                Text("Search covers filenames and recognised text.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.meta)
                Button("Clear search") { model.searchText = "" }
                    .accessibilityIdentifier("clearSearchButton")
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func shortcutRow(_ label: String, _ keys: [String]) -> some View {
        HStack(spacing: 12) {
            KeyCaps(keys: keys).frame(width: 110, alignment: .trailing)
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.meta)
        }
    }

    // MARK: Toast

    /// Bottom of the window normally. In the preview it moves to the top, so it never covers the info bar's buttons.
    @ViewBuilder
    private var toast: some View {
        if let text = model.toast {
            let inPreview = model.previewID != nil
            // The identifier sits on the capsule at its fixed size. Expanding the capsule itself would give the
            // accessibility element the whole window height, and that frame ran over the preview buttons.
            VStack {
                if !inPreview { Spacer(minLength: 0) }
                HStack(spacing: 8) {
                    Text("+")
                        .foregroundStyle(Theme.cyan)
                    Text(text)
                        .foregroundStyle(Theme.ink.opacity(0.9))
                }
                    .font(Theme.mono(11, .medium))
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.hairline, lineWidth: 1))
                    .fixedSize()
                    .accessibilityIdentifier("toast")
                if inPreview { Spacer(minLength: 0) }
            }
            .padding(inPreview ? .top : .bottom, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Opening the preview moves the toast from the bottom to the top. That move is not animated, so the
            // toast does not fly across the window; it only fades.
            .transaction(value: inPreview) { $0.animation = nil }
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }
}

/// Scroll bookkeeping the open image reads when it starts. Not state: it changes on every scroll tick.
final class ScrollBox {
    var y: CGFloat = 0
    var origin: CGPoint = .zero
}

/// Puts one card at its slot. A card whose slot moves within its row slides on a spring. One that changes row dissolves
/// out and back in at its new slot, so no card ever travels over its neighbours. While a search is showing or leaving,
/// every move glides, because the cards that do not match are faded out and nothing is in the way.
private struct CardSlot<Content: View>: View {
    let target: CGRect
    let geometryKey: String
    let glides: Bool
    let enters: Bool
    let opacity: Double
    @ViewBuilder let content: Content

    @State private var shown: CGRect?
    @State private var fade = 1.0
    @State private var arrived = false
    @State private var lastKey = ""

    var body: some View {
        let rect = shown ?? target
        content
            .frame(width: rect.width, height: rect.height, alignment: .top)
            .offset(x: rect.minX, y: rect.minY - (enters && !arrived ? 48 : 0))
            .opacity(fade * opacity * (enters && !arrived ? 0 : 1))
            .onAppear {
                lastKey = geometryKey
                if enters {
                    withAnimation(Motion.reflow) { arrived = true }
                }
            }
            .onChange(of: target) { _, new in move(to: new) }
    }

    private func move(to new: CGRect) {
        let old = shown ?? new
        defer { lastKey = geometryKey }
        if lastKey != geometryKey || old.size != new.size {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { shown = new }
        } else if glides || abs(old.minY - new.minY) < 1 {
            withAnimation(Motion.reflow) { shown = new }
        } else {
            withAnimation(.easeIn(duration: 0.1)) { fade = 0 }
            // It comes back once the neighbours sliding into its new row have settled, so nothing is drawn on top of them.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { shown = new }
                withAnimation(.easeOut(duration: 0.2)) { fade = 1 }
            }
        }
    }
}

/// Thumbnail size track for the toolbar. SwiftUI's Slider there did not take pointer clicks, so this
/// reads the drag itself. Assistive tech still gets a real slider through accessibilityRepresentation.
private struct SizeTrack: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        GeometryReader { geo in
            let span = range.upperBound - range.lowerBound
            let fraction = CGFloat((value - range.lowerBound) / span)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hairline).frame(height: 2)
                Capsule().fill(Theme.select).frame(width: max(0, geo.size.width * fraction), height: 2)
                Rectangle()
                    .fill(Theme.select)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                    .frame(width: 4, height: 14)
                    .offset(x: geo.size.width * fraction - 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let f = min(max(drag.location.x / geo.size.width, 0), 1)
                value = range.lowerBound + Double(f) * span
            })
        }
        .accessibilityRepresentation {
            Slider(value: $value, in: range)
        }
    }
}

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}
