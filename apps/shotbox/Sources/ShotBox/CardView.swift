import SwiftUI

/// One capture in the grid. Single click selects and copies; double click opens in Preview.
/// It takes plain values and compares them, so a hover, a selection or a copy redraws only the cards it touches.
struct CardView: View, Equatable {
    let model: AppModel
    let capture: Capture
    let isSelected: Bool
    let hovering: Bool
    let departing: Bool
    let previewing: Bool
    let sealShown: Bool
    let query: String
    let cardSize: Double
    /// "Before" or "After" while Esc is showing this card's place in time next to the card it landed on.
    let mark: String?
    var onActivate: () -> Void = {}

    static func == (a: CardView, b: CardView) -> Bool {
        a.capture == b.capture && a.isSelected == b.isSelected && a.hovering == b.hovering && a.departing == b.departing
            && a.previewing == b.previewing && a.sealShown == b.sealShown && a.query == b.query
            && a.cardSize == b.cardSize && a.mark == b.mark
    }

    @State private var thumb: NSImage?
    /// Until when a fresh capture still reads as OCR-pending, so its sweep and shimmer play in full
    /// even when Vision finishes first. Nil for captures that have been around for a while.
    @State private var holdUntil: Date?
    /// The matched word and where Vision found it, while a search matches this capture's recognised text.
    @State private var callout: SearchEvidence.Callout?

    private var store: Store { model.engine.store }

    /// OCR is pending while Vision runs, and for a short hold after a fresh capture arrives.
    private var ocrPending: Bool {
        capture.ocrStatus == "pending" || (holdUntil.map { $0 > Date() } ?? false)
    }

    /// Minimum time a new capture reads as pending, long enough for the scan sweep to cross the thumbnail.
    private static let ocrHold: TimeInterval = 1.2

    /// Every card has the same thumbnail bay height, so date and size lines line up along a row.
    private var bayHeight: CGFloat { GridLayout.bayHeight(cardSize) }

    /// Why the card matched the active search, with the matched term emphasised and nothing else.
    private var matchSnippet: AttributedString? {
        guard let hit = SearchEvidence.snippet(capture, query: query) else { return nil }
        var text = AttributedString(hit.text)
        if let range = hit.match, let attr = Range(range, in: text) {
            text[attr].font = .system(size: 11, weight: .bold)
            text[attr].foregroundColor = Theme.cyan
            text[attr].underlineStyle = .single
        }
        return text
    }

    /// One line under the caption: the search match, else the OCR state. Pending OCR shimmers; finished OCR with no text says so.
    /// It takes no height when it has nothing to say, so the gap under a card is one gutter, not a reserved empty line.
    @ViewBuilder
    private var statusLine: some View {
        if let snippet = matchSnippet {
            Text(snippet)
                .font(.system(size: 11))
                .foregroundStyle(Theme.meta)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(height: 16, alignment: .leading)
                .accessibilityIdentifier("cardSnippet-\(capture.id)")
                .transition(.opacity)
        } else if ocrPending {
            ShimmerLabel(text: "Reading text…")
                .frame(height: 16, alignment: .leading)
                .accessibilityIdentifier("cardOCRPending-\(capture.id)")
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
        } else if !ocrPending && capture.ocrStatus == "done" && capture.ocrText.isEmpty {
            Text("No text")
                .font(.system(size: 11))
                .foregroundStyle(Theme.coord)
                .frame(height: 16, alignment: .leading)
                .accessibilityIdentifier("cardNoText-\(capture.id)")
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // While this capture is open its bay is an empty slot. The preview image flies from the bay's rect.
            Group {
                if previewing {
                    Color.clear.frame(maxWidth: .infinity).frame(height: bayHeight)
                } else {
                    thumbnail
                }
            }
            // Every line has a fixed height, so a card with an OCR line is as tall as one without, and a row stays level.
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(Fmt.stamp(capture.created))
                        .font(Theme.mono(11, .medium))
                        .foregroundStyle(Theme.ink.opacity(0.9))
                        .lineLimit(1)
                        .accessibilityIdentifier("cardDate-\(capture.id)")
                    Spacer(minLength: 0)
                    Text(verbatim: capture.address)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.coord)
                        .lineLimit(1)
                        .accessibilityIdentifier("cardAddress-\(capture.id)")
                }
                .frame(height: 15)
                Text(verbatim: "\(capture.width) × \(capture.height)")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.meta)
                    .lineLimit(1)
                    .frame(height: 14, alignment: .leading)
                    .accessibilityIdentifier("cardSize-\(capture.id)")
                provenance
                statusLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The status line settles in with the spring when OCR finishes.
            .animation(Motion.hero, value: ocrPending)
        }
        .padding(8)
        .frame(maxHeight: .infinity, alignment: .top)
        .scaleEffect(departing ? 0.6 : 1)
        .opacity(departing ? 0 : 1)
        .accessibilityHidden(departing)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Theme.select, lineWidth: 2)
                .opacity(isSelected ? 1 : 0)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onHover { inside in
            if inside {
                model.hoveredID = capture.id
            } else if model.hoveredID == capture.id {
                model.hoveredID = nil
            }
        }
        .onTapGesture(count: 2) {
            onActivate()
            model.hoveredID = capture.id
            model.selectedID = capture.id
            model.openInPreview(capture)
        }
        .onTapGesture {
            onActivate()
            model.sealID = nil
            // A click puts the pointer on this card, so its buttons show now and the card it left drops them.
            model.hoveredID = capture.id
            model.selectedID = capture.id
            model.copy(capture)
        }
        .onDrag {
            NSItemProvider(contentsOf: store.imageURL(capture)) ?? NSItemProvider()
        }
        .contextMenu {
            Button("Copy") { model.copy(capture) }
            Button("Open in Preview") { model.openInPreview(capture) }
            Button(capture.pinned ? "Unpin" : "Pin") { model.togglePin(capture) }
            Button("Reveal in Finder") { model.reveal(capture) }
            Divider()
            Button("Delete", role: .destructive) { model.delete([capture.id]) }
        }
        .task(id: capture.id) {
            thumb = await Images.load(store.thumbURL(capture))
        }
        .task(id: "\(capture.id)|\(query)|\(capture.ocrStatus)") {
            await loadCallout()
        }
        .task(id: capture.id) {
            let until = capture.created.addingTimeInterval(Self.ocrHold)
            guard until > Date() else { return }
            holdUntil = until
            try? await Task.sleep(for: .seconds(until.timeIntervalSinceNow))
            withAnimation(Motion.hero) { holdUntil = nil }
        }
    }

    /// Finds where Vision saw the matched word. Only recognised-text matches get one; a filename match does not.
    private func loadCallout() async {
        guard !query.isEmpty, capture.ocrText.range(of: query, options: .caseInsensitive) != nil else {
            if callout != nil { callout = nil }
            return
        }
        let store = store, id = capture.id, q = query
        let found = await Task.detached(priority: .userInitiated) {
            SearchEvidence.callout(boxes: store.ocrBoxes(id), query: q)
        }.value
        withAnimation(Motion.hero) { callout = found }
    }

    /// Where the capture came from, and how often it was used, on one quiet line. A folder capture never names an app.
    private var provenance: some View {
        HStack(spacing: 6) {
            if capture.source == "screenshot-file" {
                Text("Screenshot folder")
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.coord)
                    .accessibilityIdentifier("cardSource-\(capture.id)")
            } else if let app = capture.app {
                Text(verbatim: "from \(app)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.meta)
                    .lineLimit(1)
                    .accessibilityIdentifier("cardSource-\(capture.id)")
            }
            Spacer(minLength: 0)
            if capture.uses > 0 {
                Text(verbatim: "Used \(capture.uses)×")
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.coord)
                    .accessibilityIdentifier("cardUsed-\(capture.id)")
            }
        }
        .lineLimit(1)
        .frame(height: 14, alignment: .leading)
    }

    /// The image carries the card's identifier. Identifiers on containers would overwrite their children's.
    /// The image is aspect-fit inside the fixed bay, so it is never cropped and the bay keeps its height.
    private var thumbnail: some View {
        Group {
            if let thumb {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .accessibilityIdentifier("card-\(capture.id)")
            } else {
                Color.secondary.opacity(0.08)
                    .accessibilityIdentifier("card-\(capture.id)")
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: bayHeight)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            if ocrPending {
                ScanSweep()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .transition(.opacity)
            }
        }
        .overlay {
            RegistrationTicks()
                .padding(4)
                .opacity(hovering && !isSelected ? 1 : 0)
                .animation(Motion.hero, value: hovering)
        }
        .overlay(alignment: .topLeading) {
            if capture.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(Theme.sheet.opacity(0.8), in: Circle())
                    .padding(6)
                    .accessibilityIdentifier("pinnedGlyph-\(capture.id)")
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if capture.compressed { shrunkRibbon }
        }
        .overlay { calloutView }
        .overlay(alignment: .bottomLeading) {
            if let mark {
                Text(mark.uppercased())
                    .font(Theme.mono(9, .medium))
                    .foregroundStyle(Theme.sheet)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.cyan, in: RoundedRectangle(cornerRadius: 3))
                    .padding(6)
                    .transition(.opacity)
                    .accessibilityLabel(mark)
                    .accessibilityIdentifier("neighbourMark-\(capture.id)")
            }
        }
        // The note covers the thumbnail bay and never leaves it, so it is not cut off by a card's row or the window edge.
        .overlay {
            if sealShown {
                sealNote
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .zIndex(sealShown ? 1 : 0)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 6) {
                hoverButton(capture.pinned ? "pin.slash" : "pin", id: "pinButton-\(capture.id)") {
                    model.togglePin(capture)
                }
                hoverButton("trash", id: "deleteButton-\(capture.id)") {
                    model.delete([capture.id])
                }
            }
            .padding(6)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .animation(Motion.hero, value: hovering)
        }
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline, lineWidth: 1).allowsHitTesting(false))
        .animation(Motion.hero, value: hovering)
    }

    /// The matched word, enlarged in the accent colour on the thumbnail where Vision found it, with a ring on the spot.
    @ViewBuilder
    private var calloutView: some View {
        if let callout, !query.isEmpty {
            GeometryReader { geo in
                let bay = geo.size
                let image = capture.imageRect(in: CGRect(origin: .zero, size: bay))
                let word = CGRect(x: image.minX + callout.rect.minX * image.width,
                                  y: image.minY + callout.rect.minY * image.height,
                                  width: callout.rect.width * image.width,
                                  height: callout.rect.height * image.height)
                let label = callout.word
                let boxW = min(bay.width - 8, max(48, CGFloat(label.count) * 8.5 + 18))
                let boxH: CGFloat = 24
                let cx = min(max(word.midX, boxW / 2 + 4), bay.width - boxW / 2 - 4)
                let cy = min(max(word.midY, boxH / 2 + 4), bay.height - boxH / 2 - 4)
                ZStack {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Theme.cyan, lineWidth: 1.5)
                        .frame(width: max(word.width, 6) + 4, height: max(word.height, 6) + 4)
                        .position(x: word.midX, y: word.midY)
                        .accessibilityHidden(true)
                    Text(verbatim: label)
                        .font(Theme.mono(14, .bold))
                        .foregroundStyle(Theme.cyan)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 7)
                        .frame(width: boxW, height: boxH)
                        .background(Theme.sheet.opacity(0.92), in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.cyan, lineWidth: 1.5))
                        .position(x: cx, y: cy)
                        .accessibilityLabel(label)
                        .accessibilityIdentifier("matchCallout-\(capture.id)")
                }
            }
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }

    /// A slim ribbon in the corner of a shrunk capture. Activating it opens the seal note.
    private var shrunkRibbon: some View {
        Button { model.sealID = sealShown ? nil : capture.id } label: {
            Text("SHRUNK")
                .font(Theme.mono(8, .medium))
                .foregroundStyle(Theme.sheet)
                .frame(width: 80, height: 13)
                .background(Theme.orange)
                .rotationEffect(.degrees(-45))
                .offset(x: 14, y: 14)
                .frame(width: 44, height: 44, alignment: .topLeading)
                .clipped()
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44, alignment: .bottomTrailing)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("Shrunk")
        .accessibilityIdentifier("cardCompressed-\(capture.id)")
    }

    /// What shrinking changed, and what it kept.
    private var sealNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Shrunk to a compressed copy")
                .font(.system(size: 11, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let shrunkAt = capture.shrunkAt {
                Text(verbatim: "Shrunk \(Fmt.stamp(shrunkAt))")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(verbatim: "Size \(capture.beforeBytes > 0 ? Fmt.bytes(capture.beforeBytes) : "unknown") → \(Fmt.bytes(capture.bytes))")
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: "Pixels \(capture.width) × \(capture.height) → \(capture.afterWidth) × \(capture.afterHeight)")
                .fixedSize(horizontal: false, vertical: true)
            Text("Thumbnail and recognised text were kept.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.mono(10))
        .foregroundStyle(Theme.ink.opacity(0.9))
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sheet.opacity(0.96), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .accessibilityIdentifier("sealNote-\(capture.id)")
    }

    private func hoverButton(_ symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 26, height: 26)
                .background(Theme.sheet.opacity(0.88), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

/// A thin accent line that sweeps once down the thumbnail while OCR runs, then fades out at the bottom.
private struct ScanSweep: View {
    @State private var down = false

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Theme.cyan)
                .frame(height: 1.5)
                .shadow(color: Theme.cyan.opacity(0.6), radius: 3)
                .offset(y: down ? geo.size.height : 0)
                .opacity(down ? 0 : 1)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1)) { down = true }
        }
    }
}

/// Secondary label with a light sweep across it, used while OCR is pending in place of "No text".
private struct ShimmerLabel: View {
    let text: String
    @State private var phase: CGFloat = -0.5

    var body: some View {
        Text(text)
            .font(Theme.mono(10))
            .foregroundStyle(Theme.coord)
            .overlay {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, .primary.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.5)
                        .offset(x: phase * geo.size.width)
                }
                .mask(Text(text).font(Theme.mono(10)))
            }
            .onAppear {
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { phase = 1.2 }
            }
    }
}
