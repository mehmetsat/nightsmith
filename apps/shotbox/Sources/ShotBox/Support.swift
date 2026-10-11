import AppKit

/// Decoded image cache shared by cards and the preview.
enum Images {
    /// Bounded by decoded size, so 200 thumbnails never sit in memory at once; cards reload from disk as they scroll in.
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.totalCostLimit = 48 * 1024 * 1024
        return c
    }()

    /// Already-decoded image, if the grid or a previous preview loaded it. Lets views draw on their first frame.
    static func cached(_ url: URL) -> NSImage? {
        cache.object(forKey: url.path as NSString)
    }

    static func load(_ url: URL) async -> NSImage? {
        let key = url.path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let image = await Task.detached(priority: .userInitiated) { NSImage(contentsOf: url) }.value
        if let image {
            let rep = image.representations.first
            let w = rep?.pixelsWide ?? Int(image.size.width), h = rep?.pixelsHigh ?? Int(image.size.height)
            cache.setObject(image, forKey: key, cost: max(1, w * h * 4))
        }
        return image
    }
}

enum Fmt {
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    private static let time = formatter("HH:mm")
    private static let full = formatter("d MMM yyyy, HH:mm")

    /// "Today, 13:32", "Yesterday, 13:32", otherwise "30 Aug 2026, 13:32". The same everywhere dates show.
    static func stamp(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today, \(time.string(from: date))" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday, \(time.string(from: date))" }
        return full.string(from: date)
    }

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

/// Identifiers worth copying out of recognised text: ticket IDs (ZD-48213), HTTP status codes (4xx and 5xx) and links.
enum Identifiers {
    private static let patterns = [#"\b[A-Z][A-Z0-9]{1,9}-\d{2,}\b"#, #"\b[45]\d{2}\b"#]

    /// In reading order, without repeats.
    static func find(in text: String) -> [String] {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var hits: [(location: Int, value: String)] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: whole) {
                hits.append((match.range.location, ns.substring(with: match.range)))
            }
        }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: text, range: whole) {
                hits.append((match.range.location, ns.substring(with: match.range)))
            }
        }
        var seen = Set<String>()
        return hits.sorted { $0.location < $1.location }
            .map(\.value)
            .filter { seen.insert($0).inserted }
    }
}
