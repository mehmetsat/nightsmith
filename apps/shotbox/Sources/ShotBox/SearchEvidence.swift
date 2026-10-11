import CoreGraphics
import Foundation

/// Why a capture matched the search: the text around the match, and where Vision found the matched word.
enum SearchEvidence {
    /// The recognised text around the first match with the matched range, else the filename. Nil when nothing but the
    /// app name or address matched, which the card already shows.
    static func snippet(_ c: Capture, query: String) -> (text: String, match: Range<String.Index>?)? {
        guard !query.isEmpty else { return nil }
        let text = c.ocrText
        if let range = text.range(of: query, options: .caseInsensitive) {
            let start = text.index(range.lowerBound, offsetBy: -24, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(range.upperBound, offsetBy: 32, limitedBy: text.endIndex) ?? text.endIndex
            let lead = start == text.startIndex ? "" : "…"
            let tail = end == text.endIndex ? "" : "…"
            let body = String(text[start..<end]).replacingOccurrences(of: "\n", with: " ")
            let full = lead + body + tail
            let found = full.range(of: query, options: .caseInsensitive)
            return (full, found)
        }
        if let range = c.name.range(of: query, options: .caseInsensitive) { return (c.name, range) }
        return nil
    }

    /// The word the query matched in recognised text, and its rect in the image, normalised with the origin top left.
    struct Callout: Equatable {
        let word: String
        let rect: CGRect
    }

    static func callout(boxes json: String, query: String) -> Callout? {
        guard !query.isEmpty, let data = json.data(using: .utf8),
              let lines = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        for line in lines {
            guard let text = line["t"] as? String, let words = line["k"] as? [[Double]] else { continue }
            let ns = text as NSString
            let found = ns.range(of: query, options: .caseInsensitive)
            guard found.location != NSNotFound else { continue }
            let hit = words.filter { w in
                w.count == 6 && Int(w[0]) < found.location + found.length && Int(w[0]) + Int(w[1]) > found.location
            }
            guard let first = hit.first else { continue }
            var rect = CGRect(x: first[2], y: first[3], width: first[4], height: first[5])
            var parts: [String] = []
            for w in hit {
                rect = rect.union(CGRect(x: w[2], y: w[3], width: w[4], height: w[5]))
                parts.append(ns.substring(with: NSRange(location: Int(w[0]), length: Int(w[1]))))
            }
            // Vision's origin is bottom left.
            let flipped = CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
            return Callout(word: parts.joined(separator: " "), rect: flipped)
        }
        return nil
    }
}

/// Where every card sits. Cards are placed by this plan, not by a lazy grid, so a card can glide from one plan to
/// another and the grid draws only what is on screen.
struct GridPlan {
    var slots: [Int64: CGRect] = [:]
    var cell: [Int64: (row: Int, col: Int)] = [:]
    var rows: [[Int64]] = []
    var header: CGRect?
    var pinnedCount = 0
    var height: CGFloat = 0
}

enum GridLayout {
    static let pad: CGFloat = 16
    static let headerHeight: CGFloat = 30

    static func columns(width: CGFloat, cardSize: Double) -> Int {
        max(1, Int((width - 2 * pad + 16) / CGFloat(cardSize + 16)))
    }

    static func bayHeight(_ cardSize: Double) -> CGFloat { CGFloat(cardSize) * 0.72 }

    /// A card shows a fourth line when OCR is pending or found nothing, or when a search has evidence to show.
    private static func hasStatus(_ c: Capture, query: String) -> Bool {
        c.ocrStatus == "pending" || (c.ocrStatus == "done" && c.ocrText.isEmpty)
            || (!query.isEmpty && SearchEvidence.snippet(c, query: query) != nil)
    }

    static func plan(_ items: [Capture], width: CGFloat, cardSize: Double, query: String) -> GridPlan {
        var plan = GridPlan()
        let cols = columns(width: width, cardSize: cardSize)
        let cellW = max(1, (width - 2 * pad) / CGFloat(cols))
        let base = bayHeight(cardSize) + 67
        let pinned = items.filter(\.pinned)
        let rest = items.filter { !$0.pinned }
        var y = pad
        var row = 0
        plan.pinnedCount = pinned.count
        if !pinned.isEmpty {
            plan.header = CGRect(x: pad, y: y, width: width - 2 * pad, height: headerHeight)
            plan.rows.append([])
            y += headerHeight
            row += 1
        }
        for group in [pinned, rest] where !group.isEmpty {
            for start in stride(from: 0, to: group.count, by: cols) {
                let chunk = Array(group[start..<min(start + cols, group.count)])
                let h = base + (chunk.contains { hasStatus($0, query: query) } ? 17 : 0)
                for (col, c) in chunk.enumerated() {
                    plan.slots[c.id] = CGRect(x: pad + CGFloat(col) * cellW, y: y, width: cellW, height: h)
                    plan.cell[c.id] = (row, col)
                }
                plan.rows.append(chunk.map(\.id))
                y += h
                row += 1
            }
        }
        plan.height = y + pad
        return plan
    }
}
