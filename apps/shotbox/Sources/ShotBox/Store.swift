import Foundation
import SQLite3

enum RetentionMode: String {
    case count
    case days

    /// The N a mode uses until one is committed for it.
    var defaultN: Int { self == .count ? 500 : 30 }
}

struct Retention: Equatable {
    var mode: RetentionMode
    var n: Int
}

struct Capture: Identifiable, Equatable {
    let id: Int64
    var name: String
    /// File name inside images/. Changes when the full image is shrunk, since the copy is a JPEG.
    var diskName: String
    let thumbName: String
    let created: Date
    let width: Int
    let height: Int
    var bytes: Int64
    let source: String
    var pinned: Bool
    var pinDate: Date?
    var ocrText: String
    var ocrStatus: String
    let hash: String
    /// Frontmost app when the capture was made. Nil when it could not be read.
    let app: String?
    /// True once the full image was replaced by a smaller copy. The row, thumbnail and text are unchanged.
    var compressed: Bool
    /// How many times the user copied, opened, or copied text or an identifier from this capture.
    var uses: Int
    /// When the full image was shrunk, and what it was before and after. Nil for captures never shrunk.
    var shrunkAt: Date?
    var beforeBytes: Int64
    var afterWidth: Int
    var afterHeight: Int
    /// Permanent tray address: the capture day ("2026-10-10") and the arrival number that day. Assigned once at insert.
    var addrDay: String
    var addrSeq: Int

    /// "10 OCT · 07"; the year follows the month for past years.
    var address: String { Address.label(day: addrDay, seq: addrSeq) }
    /// "10·07", the short form people type.
    var addressCompact: String { Address.compact(day: addrDay, seq: addrSeq) }
}

enum Address {
    private static let months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]

    private static func parts(_ day: String) -> (year: Int, month: Int, day: Int)? {
        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, (1...12).contains(p[1]) else { return nil }
        return (p[0], p[1], p[2])
    }

    static func label(day: String, seq: Int) -> String {
        guard let d = parts(day) else { return "—" }
        let year = d.year == Calendar.current.component(.year, from: Date()) ? "" : " \(d.year)"
        return String(format: "%02d ", d.day) + months[d.month - 1] + year + String(format: " · %02d", seq)
    }

    static func compact(day: String, seq: Int) -> String {
        guard let d = parts(day) else { return "" }
        return String(format: "%02d·%02d", d.day, seq)
    }

    static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 1, c.day ?? 1)
    }
}

/// One thing the user did with a capture. Newest first in the preview.
struct CustodyEvent: Identifiable {
    let id: Int64
    let kind: String
    let created: Date
}

struct NewCapture {
    let name: String
    let diskName: String
    let thumbName: String
    let created: Date
    let width: Int
    let height: Int
    let bytes: Int64
    let source: String
    let hash: String
    let app: String?
}

private enum DBValue {
    case text(String)
    case int(Int64)
    case double(Double)
    case null
}

enum StoreError: Error {
    case open(String)
}

/// SQLite metadata plus the on-disk image and thumbnail folders.
/// A single recursive lock serialises all statements, so it is safe to call from any queue.
final class Store {
    let dataDir: URL
    let imagesDir: URL
    let thumbsDir: URL

    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static let columns = """
        id, name, disk_name, thumb_name, created, width, height, bytes, source, pinned, pin_date, ocr_text, ocr_status, hash, app, compressed,
        (SELECT COUNT(*) FROM custody WHERE custody.capture_id = captures.id), shrunk_at, before_bytes, after_width, after_height,
        COALESCE(addr_day, ''), COALESCE(addr_seq, 0)
        """

    init(dataDir: URL) throws {
        self.dataDir = dataDir
        imagesDir = dataDir.appendingPathComponent("images", isDirectory: true)
        thumbsDir = dataDir.appendingPathComponent("thumbs", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: thumbsDir, withIntermediateDirectories: true)

        let path = dataDir.appendingPathComponent("shotbox.sqlite").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw StoreError.open(path)
        }
        exec("""
        CREATE TABLE IF NOT EXISTS captures (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          disk_name TEXT NOT NULL,
          thumb_name TEXT NOT NULL,
          created REAL NOT NULL,
          width INTEGER NOT NULL,
          height INTEGER NOT NULL,
          bytes INTEGER NOT NULL,
          source TEXT NOT NULL,
          pinned INTEGER NOT NULL DEFAULT 0,
          pin_date REAL,
          ocr_text TEXT NOT NULL DEFAULT '',
          ocr_status TEXT NOT NULL DEFAULT 'pending',
          hash TEXT NOT NULL
        )
        """)
        exec("CREATE INDEX IF NOT EXISTS captures_created ON captures(created)")
        exec("CREATE INDEX IF NOT EXISTS captures_hash ON captures(hash)")
        // Older databases predate the app column; the statement fails harmlessly once it exists.
        exec("ALTER TABLE captures ADD COLUMN app TEXT")
        exec("ALTER TABLE captures ADD COLUMN compressed INTEGER NOT NULL DEFAULT 0")
        exec("ALTER TABLE captures ADD COLUMN shrunk_at REAL")
        exec("ALTER TABLE captures ADD COLUMN before_bytes INTEGER NOT NULL DEFAULT 0")
        exec("ALTER TABLE captures ADD COLUMN after_width INTEGER NOT NULL DEFAULT 0")
        exec("ALTER TABLE captures ADD COLUMN after_height INTEGER NOT NULL DEFAULT 0")
        exec("ALTER TABLE captures ADD COLUMN addr_day TEXT")
        exec("ALTER TABLE captures ADD COLUMN addr_seq INTEGER")
        exec("ALTER TABLE captures ADD COLUMN ocr_boxes TEXT")
        // Next arrival number per day. Only ever grows, so the number of a deleted capture is not reused.
        exec("CREATE TABLE IF NOT EXISTS address_days (day TEXT PRIMARY KEY, next INTEGER NOT NULL)")
        exec("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        exec("CREATE TABLE IF NOT EXISTS custody (id INTEGER PRIMARY KEY AUTOINCREMENT, capture_id INTEGER NOT NULL, kind TEXT NOT NULL, created REAL NOT NULL)")
        exec("CREATE INDEX IF NOT EXISTS custody_capture ON custody(capture_id)")
        // A folder capture never came from an app. Rows written before that rule carried the ShotBox window's name.
        exec("UPDATE captures SET app = NULL WHERE source = 'screenshot-file'")
        backfillAddresses()
    }

    /// Rows from before addresses existed get one now, in arrival order. After this an address never changes.
    private func backfillAddresses() {
        let pending = rows("SELECT id, created FROM captures WHERE addr_day IS NULL ORDER BY created ASC, id ASC") {
            (sqlite3_column_int64($0, 0), Date(timeIntervalSince1970: sqlite3_column_double($0, 1)))
        }
        for (id, created) in pending {
            let (day, seq) = nextAddress(for: created)
            exec("UPDATE captures SET addr_day = ?, addr_seq = ? WHERE id = ?", [.text(day), .int(Int64(seq)), .int(id)])
        }
    }

    /// Takes the next arrival number for the day of `date`.
    private func nextAddress(for date: Date) -> (String, Int) {
        lock.lock()
        defer { lock.unlock() }
        let day = Address.dayKey(date)
        let seq = Int(scalar("SELECT next FROM address_days WHERE day = ?", [.text(day)]))
        let n = max(seq, 1)
        exec("INSERT INTO address_days (day, next) VALUES (?, ?) ON CONFLICT(day) DO UPDATE SET next = excluded.next", [.text(day), .int(Int64(n + 1))])
        return (day, n)
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: Captures

    /// Pinned first (by pin date), then newest first. An empty query returns everything.
    func fetch(search: String) -> [Capture] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var sql = "SELECT \(Self.columns) FROM captures"
        var args: [DBValue] = []
        if !query.isEmpty {
            let pattern = DBValue.text("%" + Self.escapeLike(query) + "%")
            // The app name only matches captures that really came from that app, never a folder capture.
            sql += " WHERE name LIKE ? ESCAPE '\\' OR ocr_text LIKE ? ESCAPE '\\' OR (app LIKE ? ESCAPE '\\' AND source = 'pasteboard')"
            args = [pattern, pattern, pattern]
        }
        sql += " ORDER BY pinned DESC, CASE WHEN pinned = 1 THEN pin_date ELSE created END DESC"
        return rows(sql, args) { Self.capture($0) }
    }

    func count() -> Int {
        Int(scalar("SELECT COUNT(*) FROM captures"))
    }

    func get(_ id: Int64) -> Capture? {
        rows("SELECT \(Self.columns) FROM captures WHERE id = ?", [.int(id)]) { Self.capture($0) }.first
    }

    func insert(_ c: NewCapture) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        let (day, seq) = nextAddress(for: c.created)
        let ok = exec(
            "INSERT INTO captures (name, disk_name, thumb_name, created, width, height, bytes, source, pinned, ocr_text, ocr_status, hash, app, addr_day, addr_seq) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, '', 'pending', ?, ?, ?, ?)",
            [.text(c.name), .text(c.diskName), .text(c.thumbName), .double(c.created.timeIntervalSince1970),
             .int(Int64(c.width)), .int(Int64(c.height)), .int(c.bytes), .text(c.source), .text(c.hash),
             c.app.map(DBValue.text) ?? .null, .text(day), .int(Int64(seq))]
        )
        return ok ? sqlite3_last_insert_rowid(db) : nil
    }

    func setOCR(_ id: Int64, text: String, status: String, boxes: String = "") {
        exec("UPDATE captures SET ocr_text = ?, ocr_status = ?, ocr_boxes = ? WHERE id = ?", [.text(text), .text(status), .text(boxes), .int(id)])
    }

    /// Where Vision found each word, as JSON. Empty for captures read before boxes were kept.
    func ocrBoxes(_ id: Int64) -> String {
        rows("SELECT COALESCE(ocr_boxes, '') FROM captures WHERE id = ?", [.int(id)]) { Self.text($0, 0) }.first ?? ""
    }

    func setPinned(_ id: Int64, _ pinned: Bool) {
        exec("UPDATE captures SET pinned = ?, pin_date = ? WHERE id = ?",
             [.int(pinned ? 1 : 0), pinned ? .double(Date().timeIntervalSince1970) : .null, .int(id)])
    }

    /// Id of a capture with the same content, however old it is. Nil when the library does not hold it yet.
    func existingID(hash: String) -> Int64? {
        rows("SELECT id FROM captures WHERE hash = ? LIMIT 1", [.text(hash)]) { sqlite3_column_int64($0, 0) }.first
    }

    /// Newest first by capture time, ignoring pins and search. Feeds the Clothesline.
    func recent(limit: Int) -> [Capture] {
        rows("SELECT \(Self.columns) FROM captures ORDER BY created DESC LIMIT ?", [.int(Int64(limit))]) { Self.capture($0) }
    }

    /// Unpinned captures created before the cutoff whose full image has not been shrunk yet.
    func shrinkCandidates(createdBefore cutoff: Date) -> [Capture] {
        rows("SELECT \(Self.columns) FROM captures WHERE pinned = 0 AND compressed = 0 AND created < ?",
             [.double(cutoff.timeIntervalSince1970)]) { Self.capture($0) }
    }

    /// Records the shrink for the seal note: when, the size before, and the pixels after.
    func markCompressed(_ id: Int64, diskName: String, bytes: Int64, beforeBytes: Int64, afterWidth: Int, afterHeight: Int) {
        exec("UPDATE captures SET disk_name = ?, bytes = ?, compressed = 1, shrunk_at = ?, before_bytes = ?, after_width = ?, after_height = ? WHERE id = ?",
             [.text(diskName), .int(bytes), .double(Date().timeIntervalSince1970), .int(beforeBytes),
              .int(Int64(afterWidth)), .int(Int64(afterHeight)), .int(id)])
    }

    /// Adds one entry to the capture's custody log. Kinds: "copied", "opened", "text-copied", "chip-copied".
    func recordEvent(_ id: Int64, _ kind: String) {
        exec("INSERT INTO custody (capture_id, kind, created) VALUES (?, ?, ?)",
             [.int(id), .text(kind), .double(Date().timeIntervalSince1970)])
    }

    /// The capture's custody log, newest first.
    func events(_ id: Int64) -> [CustodyEvent] {
        rows("SELECT id, kind, created FROM custody WHERE capture_id = ? ORDER BY created DESC, id DESC", [.int(id)]) {
            CustodyEvent(id: sqlite3_column_int64($0, 0), kind: Self.text($0, 1), created: Date(timeIntervalSince1970: sqlite3_column_double($0, 2)))
        }
    }

    /// Removes the rows and their custody logs, and returns the rows so the caller can delete their files.
    func delete(_ ids: [Int64]) -> [Capture] {
        lock.lock()
        defer { lock.unlock() }
        let removed = ids.compactMap { get($0) }
        for c in removed {
            exec("DELETE FROM custody WHERE capture_id = ?", [.int(c.id)])
            exec("DELETE FROM captures WHERE id = ?", [.int(c.id)])
        }
        return removed
    }

    /// Unpinned captures the rule will remove next, oldest first. Retention already ran at commit and on
    /// every capture, so nothing is over the limit at rest. "Next" means the next capture (count mode)
    /// or captures that pass the age limit within the next day (days mode).
    func nextToGo(_ r: Retention, limit: Int, now: Date = Date()) -> [Capture] {
        switch r.mode {
        case .count:
            let due = Int(scalar("SELECT COUNT(*) FROM captures WHERE pinned = 0")) + 1 - r.n
            guard due > 0 else { return [] }
            return rows("SELECT \(Self.columns) FROM captures WHERE pinned = 0 ORDER BY created ASC LIMIT ?",
                        [.int(Int64(min(due, limit)))]) { Self.capture($0) }
        case .days:
            let cutoff = now.addingTimeInterval(-Double(r.n) * 86_400 + 86_400)
            return rows("SELECT \(Self.columns) FROM captures WHERE pinned = 0 AND created < ? ORDER BY created ASC LIMIT ?",
                        [.double(cutoff.timeIntervalSince1970), .int(Int64(limit))]) { Self.capture($0) }
        }
    }

    /// How many captures `nextToGo` would return without a limit.
    func nextCount(_ r: Retention, now: Date = Date()) -> Int {
        switch r.mode {
        case .count:
            return max(0, Int(scalar("SELECT COUNT(*) FROM captures WHERE pinned = 0")) + 1 - r.n)
        case .days:
            let cutoff = now.addingTimeInterval(-Double(r.n) * 86_400 + 86_400)
            return Int(scalar("SELECT COUNT(*) FROM captures WHERE pinned = 0 AND created < ?", [.double(cutoff.timeIntervalSince1970)]))
        }
    }

    /// The captures `overflow` names, oldest first, for the draft preview in Settings.
    func overflowCaptures(_ r: Retention, limit: Int, now: Date = Date()) -> [Capture] {
        let ids = Set(overflow(r, now: now))
        guard !ids.isEmpty else { return [] }
        return rows("SELECT \(Self.columns) FROM captures WHERE pinned = 0 ORDER BY created ASC") { Self.capture($0) }
            .filter { ids.contains($0.id) }
            .prefix(limit).map { $0 }
    }

    /// Unpinned captures that the retention rule would remove right now.
    func overflow(_ r: Retention, now: Date = Date()) -> [Int64] {
        switch r.mode {
        case .count:
            return rows("SELECT id FROM captures WHERE pinned = 0 ORDER BY created DESC LIMIT -1 OFFSET ?",
                        [.int(Int64(r.n))]) { sqlite3_column_int64($0, 0) }
        case .days:
            let cutoff = now.addingTimeInterval(-Double(r.n) * 86_400)
            return rows("SELECT id FROM captures WHERE pinned = 0 AND created < ?",
                        [.double(cutoff.timeIntervalSince1970)]) { sqlite3_column_int64($0, 0) }
        }
    }

    // MARK: Settings

    func setting(_ key: String) -> String? {
        rows("SELECT value FROM settings WHERE key = ?", [.text(key)]) { Self.text($0, 0) }.first
    }

    func setSetting(_ key: String, _ value: String) {
        exec("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
             [.text(key), .text(value)])
    }

    func retention() -> Retention {
        let mode = RetentionMode(rawValue: setting("retention_mode") ?? "") ?? .count
        return Retention(mode: mode, n: remembered(mode))
    }

    /// The N last committed for a mode. Each mode keeps its own, so switching modes never carries one mode's N into the other.
    func remembered(_ mode: RetentionMode) -> Int {
        Int(setting("retention_n_\(mode.rawValue)") ?? "") ?? mode.defaultN
    }

    /// Age in days after which an unpinned capture's full image is shrunk. Default 30.
    func shrinkDays() -> Int {
        Int(setting("shrink_days") ?? "") ?? 30
    }

    func saveRetention(_ r: Retention) {
        setSetting("retention_mode", r.mode.rawValue)
        setSetting("retention_n_\(r.mode.rawValue)", String(r.n))
    }

    // MARK: Files

    func imageURL(_ c: Capture) -> URL {
        imagesDir.appendingPathComponent(c.diskName)
    }

    func thumbURL(_ c: Capture) -> URL {
        thumbsDir.appendingPathComponent(c.thumbName)
    }

    func diskUsage() -> Int64 {
        guard let walker = FileManager.default.enumerator(at: dataDir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    // MARK: SQLite plumbing

    static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func text(_ s: OpaquePointer?, _ i: Int32) -> String {
        guard let p = sqlite3_column_text(s, i) else { return "" }
        return String(cString: UnsafeRawPointer(p).assumingMemoryBound(to: CChar.self))
    }

    private static func capture(_ s: OpaquePointer?) -> Capture {
        Capture(
            id: sqlite3_column_int64(s, 0),
            name: text(s, 1),
            diskName: text(s, 2),
            thumbName: text(s, 3),
            created: Date(timeIntervalSince1970: sqlite3_column_double(s, 4)),
            width: Int(sqlite3_column_int64(s, 5)),
            height: Int(sqlite3_column_int64(s, 6)),
            bytes: sqlite3_column_int64(s, 7),
            source: text(s, 8),
            pinned: sqlite3_column_int64(s, 9) != 0,
            pinDate: sqlite3_column_type(s, 10) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s, 10)),
            ocrText: text(s, 11),
            ocrStatus: text(s, 12),
            hash: text(s, 13),
            app: sqlite3_column_type(s, 14) == SQLITE_NULL ? nil : text(s, 14),
            compressed: sqlite3_column_int64(s, 15) != 0,
            uses: Int(sqlite3_column_int64(s, 16)),
            shrunkAt: sqlite3_column_type(s, 17) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s, 17)),
            beforeBytes: sqlite3_column_int64(s, 18),
            afterWidth: Int(sqlite3_column_int64(s, 19)),
            afterHeight: Int(sqlite3_column_int64(s, 20)),
            addrDay: text(s, 21),
            addrSeq: Int(sqlite3_column_int64(s, 22))
        )
    }

    private func bind(_ stmt: OpaquePointer?, _ values: [DBValue]) {
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case .text(let s): sqlite3_bind_text(stmt, index, s, -1, transient)
            case .int(let n): sqlite3_bind_int64(stmt, index, n)
            case .double(let d): sqlite3_bind_double(stmt, index, d)
            case .null: sqlite3_bind_null(stmt, index)
            }
        }
    }

    @discardableResult
    private func exec(_ sql: String, _ args: [DBValue] = []) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, args)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func rows<T>(_ sql: String, _ args: [DBValue] = [], _ map: (OpaquePointer?) -> T) -> [T] {
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, args)
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(map(stmt))
        }
        return out
    }

    private func scalar(_ sql: String, _ args: [DBValue] = []) -> Int64 {
        rows(sql, args) { sqlite3_column_int64($0, 0) }.first ?? 0
    }
}
