import SwiftUI

/// Full preview over the blurred grid. An image opened from a card grows out of that card's bay and shrinks back into it on close.
struct PreviewView: View {
    @EnvironmentObject var model: AppModel
    let capture: Capture
    let store: Store
    /// Where the image starts when the preview opened from a grid card. Nil for a step to a neighbour.
    let openingRect: CGRect?

    /// The info bar and nav buttons fade in after the image has started its morph, and out as it returns.
    @State private var chromeShown = false
    /// What the user did with this capture, newest first. Reloaded when the library changes.
    @State private var events: [CustodyEvent] = []

    var body: some View {
        ZStack {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    PreviewImage(capture: capture, store: store, openingRect: openingRect, returning: model.closingPreview)
                        .id(capture.id)
                        .transition(NavSlide(model: model, captureID: capture.id))
                        .offset(x: model.previewBounce)

                    if model.showText {
                        textPanel
                            .frame(width: 280)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Steps to a neighbour animate here. Opening from the grid must not: its morph runs on the open spring,
                // and a second animation on the same change cut it.
                .animation(model.heroID == nil ? Motion.hero : nil, value: capture.id)

                infoBar
                    .opacity(chromeShown && !model.closingPreview ? 1 : 0)
            }
            .padding(20)
            .contentShape(Rectangle())
            .onTapGesture {}

            HStack {
                navButton("chevron.left", id: "previewPrev") { model.step(-1) }
                Spacer()
                navButton("chevron.right", id: "previewNext") { model.step(1) }
            }
            // With the text panel open, the right chevron stays left of the panel instead of over it.
            .padding(.leading, 28)
            .padding(.trailing, model.showText ? 28 + 280 + 12 : 28)
            .frame(maxHeight: .infinity)
            .opacity(chromeShown && !model.closingPreview ? 1 : 0)
        }
        .onAppear {
            withAnimation(Motion.open.delay(0.15)) { chromeShown = true }
            events = store.events(capture.id)
        }
        .onChange(of: capture.id) { _, id in events = store.events(id) }
        .onChange(of: model.revision) { _, _ in events = store.events(capture.id) }
    }

    private static func label(_ kind: String) -> String {
        switch kind {
        case "opened": return "Opened"
        case "text-copied": return "Text copied"
        case "chip-copied": return "Chip copied"
        default: return "Copied"
        }
    }

    private var infoBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(capture.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("previewFilename")
                ScrollView(.horizontal, showsIndicators: false) {
                  HStack(spacing: 10) {
                    Text(verbatim: capture.address).accessibilityIdentifier("previewAddress")
                    Text(Fmt.stamp(capture.created)).accessibilityIdentifier("previewDate")
                    Text(verbatim: "\(capture.width) × \(capture.height)").accessibilityIdentifier("previewSize")
                    Text(Fmt.bytes(capture.bytes)).accessibilityIdentifier("previewFileSize")
                    Label(ocrLabel, systemImage: "text.viewfinder").accessibilityIdentifier("previewOCRStatus")
                  }
                  .font(Theme.mono(10))
                  .foregroundStyle(Theme.meta)
                }
                if !events.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(events) { event in
                                Text(verbatim: "\(Self.label(event.kind)) \(Fmt.stamp(event.created))")
                            }
                        }
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.coord)
                    }
                    .accessibilityIdentifier("previewHistory")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView(.horizontal, showsIndicators: false) {
              HStack(spacing: 8) {
                Button { model.copy(capture) } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .accessibilityIdentifier("previewCopy")

                Button { model.openInPreview(capture) } label: {
                    Label("Open in Preview", systemImage: "eye")
                }
                .accessibilityIdentifier("previewOpenInPreview")

                Button { model.togglePin(capture) } label: {
                    Label(capture.pinned ? "Unpin" : "Pin", systemImage: capture.pinned ? "pin.slash" : "pin")
                }
                .accessibilityIdentifier("previewPin")

                Button(role: .destructive) { model.deleteCurrent() } label: {
                    Label("Delete", systemImage: "trash")
                }
                .accessibilityIdentifier("previewDelete")

                Button { model.toggleText() } label: {
                    Label("Text", systemImage: "text.viewfinder")
                }
                .accessibilityIdentifier("previewTextToggle")

                Button { model.closePreview() } label: {
                    Label("Close", systemImage: "xmark")
                }
                .accessibilityIdentifier("previewClose")
              }
              .buttonStyle(.bordered)
              .controlSize(.small)
            }
        }
        .padding(12)
        .background(Theme.sheet, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.hairline, lineWidth: 1))
    }

    private var ocrLabel: String {
        if capture.ocrStatus == "pending" { return "Reading text…" }
        return capture.ocrText.isEmpty ? "No text" : "Text recognised"
    }

    private var textPanel: some View {
        let chips = Identifiers.find(in: capture.ocrText)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Recognised text")
                    .sectionLabel()
                    .accessibilityIdentifier("ocrPanel")
                Spacer(minLength: 0)
                Button { model.copyText(capture.ocrText, of: capture.id) } label: {
                    Label("Copy text", systemImage: "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                }
                .controlSize(.small)
                .disabled(capture.ocrText.isEmpty)
                .accessibilityIdentifier("ocrCopyText")
            }
            ScrollView {
                Text(capture.ocrText.isEmpty ? "No text recognised" : capture.ocrText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("ocrText")
            }
            if !chips.isEmpty {
                Text("Identifiers")
                    .sectionLabel()
                // One chip per line, full width, so a long URL wraps instead of being cut to "https:/…".
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(chips, id: \.self) { chip in
                        Button { model.copyText(chip, of: capture.id, kind: "chip-copied") } label: {
                            Text(chip)
                                .font(.system(size: 11, design: .monospaced))
                                .multilineTextAlignment(.leading)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .foregroundStyle(Theme.cyan)
                                .background(Theme.sheet, in: RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.hairline, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help("Copy \(chip)")
                        .accessibilityIdentifier("chip-\(chip)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.hairline, lineWidth: 1))
    }

    private func navButton(_ symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 40, height: 40)
                .background(Theme.sheet.opacity(0.9), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

/// Navigation slide for the preview image. The outgoing image moves away from the way the user is heading and
/// shrinks a little; the incoming one enters from the opposite edge. It reads the model when it runs, because a
/// removed view keeps the transition from its last render. A static transition made the outgoing image vanish
/// with no motion. The card-opened image (the hero) gets no offset, so its morph from the grid is unchanged.
private struct NavSlide: Transition {
    let model: AppModel
    let captureID: Int64

    func body(content: Content, phase: TransitionPhase) -> some View {
        let moving = model.heroID != captureID && !phase.isIdentity
        let direction: CGFloat = model.previewForward ? 1 : -1
        let leaving = phase == .didDisappear
        // Only the offset and the scale move. A fade here made the pair read as a cross-fade, not a slide.
        content
            .offset(x: moving ? (leaving ? -direction : direction) * 220 : 0)
            .scaleEffect(moving && leaving ? 0.92 : 1)
    }
}

/// One preview image. It is created per capture (see `.id` above), so it can seed its state from the cache
/// before its first frame. An empty image on insertion would make the morph a cut.
private struct PreviewImage: View {
    let capture: Capture
    let store: Store
    /// Where the image starts: its card's bay. Nil when there is no morph.
    let openingRect: CGRect?
    /// True while the image flies back to its card.
    let returning: Bool

    @State private var image: NSImage?
    /// False while the image sits at its card; it springs to true where it is shown in the preview.
    @State private var landed = false

    init(capture: Capture, store: Store, openingRect: CGRect?, returning: Bool) {
        self.capture = capture
        self.store = store
        self.openingRect = openingRect
        self.returning = returning
        // Cached full image, else the cached thumbnail the grid already decoded.
        _image = State(initialValue: Images.cached(store.imageURL(capture)) ?? Images.cached(store.thumbURL(capture)))
    }

    var body: some View {
        GeometryReader { geo in
            // The image is drawn at its final rect. Until it lands it is scaled and moved so it sits on its card's bay.
            let box = geo.frame(in: .named("mainSpace"))
            let shown = capture.imageRect(in: box)
            let from = openingRect ?? shown
            let morphing = openingRect != nil && !landed
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: shown.width, height: shown.height)
                        .overlay(RectangleRegistration())
                        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
                        .accessibilityIdentifier("previewImage")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scaleEffect(morphing ? from.width / shown.width : 1)
            .offset(x: morphing ? from.midX - shown.midX : 0, y: morphing ? from.midY - shown.midY : 0)
        }
        .onAppear {
            guard openingRect != nil else { return }
            withAnimation(Motion.open) { landed = true }
        }
        .onChange(of: returning) { _, back in
            guard openingRect != nil else { return }
            withAnimation(Motion.open) { landed = !back }
        }
        .task {
            // Thumbnail first (usually cached from the grid), then the full image.
            if image == nil, let thumb = await Images.load(store.thumbURL(capture)) { image = thumb }
            if let full = await Images.load(store.imageURL(capture)) { image = full }
        }
    }
}

private struct RectangleRegistration: View {
    var body: some View { RegistrationTicks(length: 9).padding(-5) }
}
