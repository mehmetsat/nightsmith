import AppKit
import Darwin
import CryptoKit
import ImageIO
import Vision

/// Watches the screenshot folder and the pasteboard, turns new images into captures,
/// runs OCR and enforces retention. Polling and UI-facing state run on the main thread;
/// decoding, hashing, writing and OCR run on background queues.
final class Engine {
    let store: Store
    var onChange: (() -> Void)?
    /// Called on the main thread with the id of the existing capture when an incoming image is already saved.
    var onDuplicate: ((Int64) -> Void)?
    /// The screenshot folder is watched only while this is on. Clipboard capture does not depend on it.
    var watchFolderEnabled = true {
        didSet {
            // Files that land while the folder is unwatched are baseline, the same as files seen during a pause.
            if !oldValue, watchFolderEnabled { seenKeys.formUnion(watchEntries().map(\.key)) }
        }
    }
    var paused = false {
        didSet {
            // Files that are still being written when capture resumes arrived during the pause. Treat
            // everything in the folder as seen, so only files that show up after resume are captured.
            if oldValue, !paused { seenKeys.formUnion(watchEntries().map(\.key)) }
        }
    }

    private struct Entry {
        let key: String
        let url: URL
        let name: String
        let modified: Date
        let size: Int64
    }

    private let watchDir = Config.watchDir
    private let ingestQueue = DispatchQueue(label: "shotbox.ingest", qos: .utility)
    private let ocrQueue = DispatchQueue(label: "shotbox.ocr", qos: .utility)
    private var seenKeys = Set<String>()
    private var lastPasteboardCount = NSPasteboard.general.changeCount
    private var timers: [Timer] = []

    /// Long edge, in pixels, of a shrunk full image.
    private static let shrinkEdge = 1600

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    init(store: Store) {
        self.store = store
        try? FileManager.default.createDirectory(at: watchDir, withIntermediateDirectories: true)
        // Files already in the watch folder at launch are a baseline, not new captures.
        seenKeys = Set(watchEntries().map(\.key))
        timers.append(Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.scanFolder() })
        timers.append(Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkPasteboard() })
    }

    // MARK: Watch folder

    private func watchEntries() -> [Entry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: watchDir.path) else { return [] }
        return names.compactMap { name in
            guard !name.hasPrefix("."),
                  ["png", "jpg", "jpeg"].contains((name as NSString).pathExtension.lowercased()) else { return nil }
            let url = watchDir.appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let modified = attrs[.modificationDate] as? Date,
                  let size = (attrs[.size] as? NSNumber)?.int64Value else { return nil }
            return Entry(key: "\(name)|\(modified.timeIntervalSince1970)|\(size)", url: url, name: name, modified: modified, size: size)
        }
    }

    private func scanFolder() {
        guard watchFolderEnabled else { return }
        let now = Date()
        for entry in watchEntries() where !seenKeys.contains(entry.key) {
            // Skip files still being written; they are picked up on a later tick.
            guard entry.size > 0, now.timeIntervalSince(entry.modified) > 1 else { continue }
            seenKeys.insert(entry.key)
            guard !paused else { continue }
            // A file from the folder has no app of its own. The frontmost app is not where it came from.
            ingestQueue.async {
                guard let data = try? Data(contentsOf: entry.url) else { return }
                autoreleasepool { self.ingest(data, name: entry.name, source: "screenshot-file", app: nil, convertToPNG: false) }
            }
        }
    }

    // MARK: Pasteboard

    private func checkPasteboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastPasteboardCount else { return }
        lastPasteboardCount = pb.changeCount
        guard !paused else { return }
        // Text and other non-image content has no png or tiff data, so it is ignored here.
        let png = pb.data(forType: .png)
        guard let data = png ?? pb.data(forType: .tiff) else { return }
        let name = "Pasteboard \(Self.stampFormatter.string(from: Date())).png"
        let app = frontmostAppName()
        ingestQueue.async {
            autoreleasepool { self.ingest(data, name: name, source: "pasteboard", app: app, convertToPNG: png == nil) }
        }
    }

    /// Puts plain text on the pasteboard. Text is ignored by capture, so this never makes a capture.
    func copyText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        lastPasteboardCount = pb.changeCount
    }

    /// Puts an image we wrote ourselves on the pasteboard without re-capturing it.
    func copyToPasteboard(_ c: Capture) {
        guard let image = NSImage(contentsOf: store.imageURL(c)) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
        lastPasteboardCount = pb.changeCount
    }

    /// Name of the frontmost app, or nil when macOS does not report one.
    private func frontmostAppName() -> String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    // MARK: Ingest

    /// Runs on ingestQueue. Stores the image file, thumbnail and row, then starts OCR.
    private func ingest(_ data: Data, name: String, source: String, app: String?, convertToPNG: Bool) {
        defer { DispatchQueue.main.async { self.onChange?() } }
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumb = Self.thumbnail(src, maxPixel: 512),
              let full = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return }

        // Same pixels as anything already in the library (from any time) is not stored again.
        let hash = Self.hash(full, width: width, height: height)
        if let existing = store.existingID(hash: hash) {
            DispatchQueue.main.async { self.onDuplicate?(existing) }
            return
        }

        let fileData = convertToPNG ? (Self.pngData(src) ?? data) : data
        let diskName = uniqueImageName(name)
        let thumbName = UUID().uuidString + ".jpg"
        let imageURL = store.imagesDir.appendingPathComponent(diskName)
        let thumbURL = store.thumbsDir.appendingPathComponent(thumbName)
        do {
            try Self.writeJPEG(thumb, to: thumbURL)
            try fileData.write(to: imageURL)
        } catch {
            remove(thumbURL, imageURL)
            return
        }

        let row = NewCapture(name: name, diskName: diskName, thumbName: thumbName, created: Date(),
                             width: width, height: height, bytes: Int64(fileData.count), source: source, hash: hash,
                             app: app)
        guard let id = store.insert(row) else {
            remove(thumbURL, imageURL)
            return
        }

        ocrQueue.async {
            // The stored file holds the same pixels; the helper reads it from disk, in its own process.
            let read = OCRClient.shared.recognize(imageURL) ?? autoreleasepool { Self.recognizeText(data) }
            self.store.setOCR(id, text: read?.text ?? "", status: read == nil ? "failed" : "done", boxes: read?.boxes ?? "")
            DispatchQueue.main.async { self.onChange?() }
            self.relieveMemory()
        }
        enforceRetention()
    }

    /// Decoding and OCR leave freed pages that malloc keeps. Handing them back once the queues go quiet keeps the
    /// resident size where it was before a burst of captures.
    private var reliefWork: DispatchWorkItem?
    private func relieveMemory() {
        DispatchQueue.main.async {
            self.reliefWork?.cancel()
            let work = DispatchWorkItem { _ = malloc_zone_pressure_relief(nil, 0) }
            self.reliefWork = work
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: work)
        }
    }

    private func uniqueImageName(_ name: String) -> String {
        let ns = name as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        var candidate = name
        var n = 2
        while FileManager.default.fileExists(atPath: store.imagesDir.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            n += 1
        }
        return candidate
    }

    // MARK: Deletion, pinning, retention

    /// Deletes rows and their files. Called on the main thread for user actions.
    func delete(_ ids: [Int64]) {
        deleteCaptures(ids)
        DispatchQueue.main.async { self.onChange?() }
    }

    func setPinned(_ id: Int64, _ pinned: Bool) {
        store.setPinned(id, pinned)
    }

    /// Runs retention now, off the main thread. `completion` gets how many captures were removed.
    func applyRetention(completion: ((Int) -> Void)? = nil) {
        ingestQueue.async {
            let removed = self.enforceRetention()
            DispatchQueue.main.async {
                completion?(removed)
                self.onChange?()
            }
        }
    }

    @discardableResult
    private func enforceRetention() -> Int {
        let ids = store.overflow(store.retention())
        deleteCaptures(ids)
        shrinkAged()
        return ids.count
    }

    /// Replaces the full image of old, unpinned captures with a JPEG whose long edge is at most 1600 px.
    /// The row, thumbnail and recognised text stay, so the capture is still searchable and copyable.
    private func shrinkAged() {
        let cutoff = Date().addingTimeInterval(-Double(store.shrinkDays()) * 86_400)
        // An image whose long edge is already within the limit has nothing to gain from a resize. A JPEG of a small
        // PNG can even come out larger, so those are left as they are.
        for c in store.shrinkCandidates(createdBefore: cutoff) where max(c.width, c.height) > Self.shrinkEdge {
            shrink(c)
        }
    }

    private func shrink(_ c: Capture) {
        let old = store.imageURL(c)
        guard let src = CGImageSourceCreateWithURL(old as CFURL, nil),
              let img = Self.thumbnail(src, maxPixel: Self.shrinkEdge) else { return }
        let name = uniqueImageName((c.diskName as NSString).deletingPathExtension + ".jpg")
        let url = store.imagesDir.appendingPathComponent(name)
        do {
            try Self.writeJPEG(img, to: url)
        } catch {
            remove(url)
            return
        }
        let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        // Keep the original when the copy is not smaller, so shrinking never grows the library.
        guard bytes < c.bytes else {
            remove(url)
            return
        }
        store.markCompressed(c.id, diskName: name, bytes: bytes, beforeBytes: c.bytes, afterWidth: img.width, afterHeight: img.height)
        remove(old)
    }

    private func deleteCaptures(_ ids: [Int64]) {
        guard !ids.isEmpty else { return }
        for c in store.delete(ids) {
            remove(store.imageURL(c), store.thumbURL(c))
        }
    }

    private func remove(_ urls: URL...) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Opening and revealing

    func openInPreview(_ c: Capture) {
        let url = store.imageURL(c)
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func reveal(_ c: Capture) {
        NSWorkspace.shared.activateFileViewerSelecting([store.imageURL(c)])
    }

    // MARK: Image helpers

    static func thumbnail(_ src: CGImageSource, maxPixel: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary)
    }

    /// SHA-256 over a 64 px square rendition of the full-resolution decode, plus the original dimensions.
    /// The full decode is the same for a PNG file and its pasteboard TIFF. ImageIO's own thumbnails are not:
    /// they differ by a few levels per channel between the two sources, which broke dedupe across paths.
    static func hash(_ img: CGImage, width: Int, height: Int) -> String {
        let side = 64
        var pixels = Data(count: side * side * 4)
        pixels.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.interpolationQuality = .high
            ctx?.draw(img, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        var sha = SHA256()
        sha.update(data: Data("\(width)x\(height)".utf8))
        sha.update(data: pixels)
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func pngData(_ src: CGImageSource) -> Data? {
        guard let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    static func writeJPEG(_ img: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Vision OCR on a 2048 px rendition. Returns nil when the request fails. `boxes` is JSON: per recognised line its
    /// text and, per word, the UTF-16 range and the normalised rect (origin bottom left) Vision found it in.
    private static let ocrLock = NSLock()
    private static let sharedRequest: VNRecognizeTextRequest = {
        let r = VNRecognizeTextRequest()
        r.recognitionLevel = .accurate
        r.usesLanguageCorrection = true
        return r
    }()

    static func recognizeText(_ data: Data) -> (text: String, boxes: String)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = thumbnail(src, maxPixel: 2048) else { return nil }
        // One request for the whole run: Vision keeps per-request caches, which add up over a few hundred captures.
        ocrLock.lock()
        defer { ocrLock.unlock() }
        let request = sharedRequest
        do {
            try VNImageRequestHandler(cgImage: img, options: [:]).perform([request])
        } catch {
            return nil
        }
        var lines: [String] = []
        var records: [[String: Any]] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let string = candidate.string
            lines.append(string)
            var words: [[Double]] = []
            var start = string.startIndex
            while start < string.endIndex {
                if string[start].isWhitespace { start = string.index(after: start); continue }
                var end = start
                while end < string.endIndex, !string[end].isWhitespace { end = string.index(after: end) }
                let range = start..<end
                if let box = try? candidate.boundingBox(for: range) {
                    let b = box.boundingBox
                    let ns = NSRange(range, in: string)
                    words.append([Double(ns.location), Double(ns.length), b.minX, b.minY, b.width, b.height])
                }
                start = end
            }
            records.append(["t": string, "k": words])
        }
        let json = (try? JSONSerialization.data(withJSONObject: records)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return (lines.joined(separator: "\n"), json)
    }
}
