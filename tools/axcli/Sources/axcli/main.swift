// axcli: small accessibility CLI for the evaluator agent.
//
//   axcli check
//   axcli windows [--app X]
//   axcli window-id [--app X] [--title T]   prints "<id> <x>,<y>,<w>,<h>"
//   axcli tree    [--app X] [--window N|title] [--menubar] [--depth N]
//   axcli find    <text> [--role AXButton] [--app X]   flat list of matching elements
//   axcli click   <id> [--app X] [--mouse]
//   axcli type    <id> <text> [--app X] [--global]
//   axcli key     <combo> [--app X] [--global]          e.g. cmd+shift+3, return, down
//   axcli pbimage <file.png>                  put an image on the general pasteboard
//   axcli pbinfo                              what is on the pasteboard (types, image size, hash)
//   axcli fixture <out.png> <label> [--size WxH] [--color 0.2,0.5,0.8]   make a test image
//
// Element ids:
//   "@Save"   first element whose AXIdentifier, else title or description, equals "Save".
//             Stable across UI changes; prefer it.
//   "w0.3.1"  path: window 0, child 3, child 1. Shifts when the UI changes; re-run tree.
//   "m.0"     the app's menubar extras (status item); "b.2" the main menu bar.
//
// Input never touches the user's other apps by default: key and type post events
// to the target app's process only. --global posts to the system event stream
// (needed for system hotkeys like cmd+shift+3). click uses AXPress; --mouse moves
// the real mouse pointer and is only for elements without AXPress.
// The app comes from --app (name, bundle id or pid) or $AXCLI_APP.
// All output is JSON on stdout. Errors are JSON on stderr with exit code 1.

import AppKit
import ApplicationServices
import Foundation

// MARK: - Output

func emit(_ obj: Any) {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

func fail(_ message: String) -> Never {
    let data = try! JSONSerialization.data(withJSONObject: ["error": message], options: [.sortedKeys])
    FileHandle.standardError.write(data)
    FileHandle.standardError.write("\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - Args

var positional: [String] = []
var options: [String: String] = [:]
var flags: Set<String> = []
do {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        if arg.hasPrefix("--") {
            let key = String(arg.dropFirst(2))
            if ["menubar", "pretty", "prompt", "global", "mouse"].contains(key) { flags.insert(key); continue }
            guard let value = it.next() else { fail("missing value for --\(key)") }
            options[key] = value
        } else {
            positional.append(arg)
        }
    }
}

// MARK: - App lookup

func findApp(_ query: String?) -> NSRunningApplication? {
    guard let q = query ?? ProcessInfo.processInfo.environment["AXCLI_APP"], !q.isEmpty else { return nil }
    if let pid = pid_t(q) { return NSRunningApplication(processIdentifier: pid) }
    let apps = NSWorkspace.shared.runningApplications
    return apps.first { $0.bundleIdentifier == q }
        ?? apps.first { $0.localizedName?.caseInsensitiveCompare(q) == .orderedSame }
        ?? apps.first { $0.executableURL?.lastPathComponent == q }
}

func requireApp() -> NSRunningApplication {
    let q = options["app"] ?? ProcessInfo.processInfo.environment["AXCLI_APP"]
    guard q != nil else { fail("no app given: pass --app <name|bundle id|pid> or set AXCLI_APP") }
    guard let app = findApp(q) else { fail("app not running: \(q!)") }
    return app
}

func requireTrust() {
    if !AXIsProcessTrusted() {
        fail("Accessibility permission missing for this terminal. Grant it in System Settings > Privacy & Security > Accessibility. Do not try to work around this.")
    }
}

// MARK: - AX helpers

func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    let err = AXUIElementCopyAttributeValue(el, name as CFString, &value)
    return err == .success ? value : nil
}

func str(_ el: AXUIElement, _ name: String) -> String? {
    guard let v = attr(el, name) else { return nil }
    if let s = v as? String { return s.isEmpty ? nil : s }
    if let n = v as? NSNumber { return n.stringValue }
    return nil
}

func children(_ el: AXUIElement) -> [AXUIElement] {
    (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func actions(_ el: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(el, &names) == .success, let arr = names as? [String] else { return [] }
    return arr
}

func frame(_ el: AXUIElement) -> CGRect? {
    guard let p = attr(el, kAXPositionAttribute), let s = attr(el, kAXSizeAttribute) else { return nil }
    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
          AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}

func truncate(_ s: String, _ n: Int = 200) -> String {
    s.count <= n ? s : String(s.prefix(n)) + "…"
}

func windows(_ appEl: AXUIElement) -> [AXUIElement] {
    (attr(appEl, kAXWindowsAttribute) as? [AXUIElement]) ?? []
}

/// Every element under the app's windows and menubar extras, with its path id.
func walk(_ appEl: AXUIElement, limit: Int = 8000, _ visit: (AXUIElement, String) -> Bool) {
    var queue: [(AXUIElement, String)] = windows(appEl).enumerated().map { ($1, "w\($0)") }
    if let bar = attr(appEl, "AXExtrasMenuBar") { queue.append((bar as! AXUIElement, "m")) }
    var seen = 0
    while !queue.isEmpty, seen < limit {
        let (el, id) = queue.removeFirst()
        seen += 1
        if !visit(el, id) { return }
        for (i, k) in children(el).enumerated() { queue.append((k, "\(id).\(i)")) }
    }
}

/// Resolves an id like "@Save", "w0.3.1", "m.0" or "b.2" to an element.
func resolve(_ id: String, app appEl: AXUIElement) -> AXUIElement {
    if id.hasPrefix("@") {
        let key = String(id.dropFirst())
        var byIdent: AXUIElement?, byLabel: AXUIElement?
        walk(appEl) { el, _ in
            if str(el, kAXIdentifierAttribute) == key { byIdent = el; return false }
            if byLabel == nil, str(el, kAXTitleAttribute) == key || str(el, kAXDescriptionAttribute) == key { byLabel = el }
            return true
        }
        guard let found = byIdent ?? byLabel else { fail("no element with identifier, title or description '\(key)'. Use find.") }
        return found
    }
    var parts = id.split(separator: ".").map(String.init)
    guard !parts.isEmpty else { fail("empty id") }
    let root = parts.removeFirst()
    var el: AXUIElement
    if root == "m" {
        guard let bar = attr(appEl, "AXExtrasMenuBar") else { fail("app has no menubar extras") }
        el = bar as! AXUIElement
    } else if root == "b" {
        guard let bar = attr(appEl, kAXMenuBarAttribute) else { fail("app has no menu bar") }
        el = bar as! AXUIElement
    } else if root.hasPrefix("w"), let idx = Int(root.dropFirst()) {
        let ws = windows(appEl)
        guard idx < ws.count else { fail("window \(idx) not found; app has \(ws.count) windows") }
        el = ws[idx]
    } else {
        fail("bad id '\(id)': must start with wN, m or b")
    }
    for part in parts {
        guard let i = Int(part) else { fail("bad id segment '\(part)' in '\(id)'") }
        let kids = children(el)
        guard i < kids.count else { fail("id '\(id)' not found: element has \(kids.count) children at segment \(part). Re-run tree.") }
        el = kids[i]
    }
    return el
}

// MARK: - Tree

var nodeCount = 0
let maxNodes = Int(options["max-nodes"] ?? "") ?? 3000

func dump(_ el: AXUIElement, id: String, depth: Int, maxDepth: Int) -> [String: Any] {
    nodeCount += 1
    var node: [String: Any] = ["id": id]
    node["role"] = str(el, kAXRoleAttribute) ?? "?"
    if let v = str(el, kAXSubroleAttribute) { node["subrole"] = v }
    if let v = str(el, kAXTitleAttribute) { node["title"] = truncate(v) }
    if let v = str(el, kAXValueAttribute) { node["value"] = truncate(v) }
    if let v = str(el, kAXDescriptionAttribute) { node["desc"] = truncate(v) }
    if let v = str(el, kAXHelpAttribute) { node["help"] = truncate(v) }
    if let v = str(el, kAXIdentifierAttribute) { node["identifier"] = v }
    if let f = frame(el) {
        node["frame"] = [Int(f.origin.x), Int(f.origin.y), Int(f.width), Int(f.height)]
    }
    if let e = attr(el, kAXEnabledAttribute) as? Bool, !e { node["enabled"] = false }
    if let f = attr(el, kAXFocusedAttribute) as? Bool, f { node["focused"] = true }
    if let s = attr(el, kAXSelectedAttribute) as? Bool, s { node["selected"] = true }
    let acts = actions(el).filter { $0 != "AXShowMenu" && $0 != "AXScrollToVisible" && !$0.hasPrefix("Name:") }
    if !acts.isEmpty { node["actions"] = acts }

    let kids = children(el)
    if !kids.isEmpty {
        if depth >= maxDepth || nodeCount >= maxNodes {
            node["children_truncated"] = kids.count
        } else {
            var out: [[String: Any]] = []
            for (i, k) in kids.enumerated() {
                if nodeCount >= maxNodes { node["children_truncated"] = kids.count - i; break }
                out.append(dump(k, id: "\(id).\(i)", depth: depth + 1, maxDepth: maxDepth))
            }
            node["children"] = out
        }
    }
    return node
}

// MARK: - Window list (CoreGraphics)

func cgWindows(pid: pid_t?) -> [[String: Any]] {
    guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
    return list.compactMap { w in
        let owner = w[kCGWindowOwnerPID as String] as? pid_t ?? -1
        if let pid, owner != pid { return nil }
        let layer = w[kCGWindowLayer as String] as? Int ?? 0
        let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        let width = Int(b["Width"] ?? 0), height = Int(b["Height"] ?? 0)
        if width < 2 || height < 2 { return nil }
        var out: [String: Any] = [
            "window_id": w[kCGWindowNumber as String] as? Int ?? 0,
            "pid": owner,
            "owner": w[kCGWindowOwnerName as String] as? String ?? "",
            "layer": layer,
            "onscreen": w[kCGWindowIsOnscreen as String] as? Bool ?? false,
            "frame": [Int(b["X"] ?? 0), Int(b["Y"] ?? 0), width, height],
        ]
        if let t = w[kCGWindowName as String] as? String, !t.isEmpty { out["title"] = t }
        return out
    }
}

// MARK: - Keyboard

let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
    "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
    "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "enter": 36,
    "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45,
    "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50, "delete": 51, "backspace": 51,
    "escape": 53, "esc": 53, "forwarddelete": 117, "home": 115, "end": 119,
    "pageup": 116, "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
    "f9": 101, "f10": 109, "f11": 103, "f12": 111,
]

let modifierFlags: [String: CGEventFlags] = [
    "cmd": .maskCommand, "command": .maskCommand,
    "shift": .maskShift,
    "alt": .maskAlternate, "option": .maskAlternate, "opt": .maskAlternate,
    "ctrl": .maskControl, "control": .maskControl,
    "fn": .maskSecondaryFn,
]

func post(_ e: CGEvent, to pid: pid_t?) {
    if let pid { e.postToPid(pid) } else { e.post(tap: .cghidEventTap) }
}

func pressCombo(_ combo: String, pid: pid_t?) {
    let parts = combo.lowercased().split(separator: "+").map(String.init)
    guard let keyName = parts.last, let code = keyCodes[keyName] else { fail("unknown key in '\(combo)'") }
    var flags: CGEventFlags = []
    for m in parts.dropLast() {
        guard let f = modifierFlags[m] else { fail("unknown modifier '\(m)' in '\(combo)'") }
        flags.insert(f)
    }
    let src = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)!
    let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)!
    down.flags = flags
    up.flags = flags
    post(down, to: pid)
    usleep(20_000)
    post(up, to: pid)
}

func typeText(_ text: String, pid: pid_t?) {
    let src = CGEventSource(stateID: .hidSystemState)
    for scalar in text.utf16 {
        var c = scalar
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)!
        let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)!
        down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
        up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
        post(down, to: pid)
        post(up, to: pid)
        usleep(8_000)
    }
}

func mouseClick(at p: CGPoint, double: Bool = false) {
    let src = CGEventSource(stateID: .hidSystemState)
    let clicks = double ? 2 : 1
    for n in 1...clicks {
        let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)!
        let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)!
        down.setIntegerValueField(.mouseEventClickState, value: Int64(n))
        up.setIntegerValueField(.mouseEventClickState, value: Int64(n))
        down.post(tap: .cghidEventTap)
        usleep(15_000)
        up.post(tap: .cghidEventTap)
        usleep(60_000)
    }
}

func activate(_ app: NSRunningApplication) {
    if !app.isActive {
        app.activate()
        usleep(250_000)
    }
}

// MARK: - Commands

guard let command = positional.first else {
    fail("usage: axcli check | windows | window-id | tree | find <text> | click <id> | doubleclick <id> | type <id> <text> | key <combo> | pbimage <file> | fixture <out> <label>  [--app X]")
}

switch command {
case "check":
    if flags.contains("prompt") {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    // A locked screen blocks screenshots and accessibility for every app; callers must wait.
    let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
    let locked = (session["CGSSessionScreenIsLocked"] as? Bool) ?? ((session["CGSSessionScreenIsLocked"] as? Int) == 1)
    emit(["accessibility": AXIsProcessTrusted(), "screen_recording": CGPreflightScreenCaptureAccess(), "screen_locked": locked])

case "windows":
    let pid = options["app"] != nil || ProcessInfo.processInfo.environment["AXCLI_APP"] != nil
        ? requireApp().processIdentifier : nil
    emit(cgWindows(pid: pid))

case "window-id":
    // Prints "<window_id> <x>,<y>,<w>,<h>" for the app's biggest on-screen normal window.
    let app = requireApp()
    let title = options["title"]
    let candidates = cgWindows(pid: app.processIdentifier).filter { w in
        guard w["onscreen"] as? Bool == true, w["layer"] as? Int == 0 else { return false }
        if let title { return (w["title"] as? String ?? "").localizedCaseInsensitiveContains(title) }
        return true
    }
    let best = candidates.max { a, b in
        let fa = a["frame"] as! [Int], fb = b["frame"] as! [Int]
        return fa[2] * fa[3] < fb[2] * fb[3]
    }
    guard let best else { fail("no on-screen window for \(app.localizedName ?? "app")\(title.map { " with title '\($0)'" } ?? "")") }
    let f = best["frame"] as! [Int]
    print("\(best["window_id"]!) \(f[0]),\(f[1]),\(f[2]),\(f[3])")

case "find":
    requireTrust()
    guard positional.count >= 2 else { fail("usage: axcli find <text> [--role R]") }
    let app = requireApp()
    let needle = positional[1]
    let role = options["role"]
    var hits: [[String: Any]] = []
    walk(AXUIElementCreateApplication(app.processIdentifier)) { el, id in
        if let role, str(el, kAXRoleAttribute) != role { return true }
        let fields = [kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute]
        guard needle == "*" || fields.contains(where: { (str(el, $0) ?? "").localizedCaseInsensitiveContains(needle) }) else { return true }
        var node = dump(el, id: id, depth: 0, maxDepth: 0)
        if let n = node.removeValue(forKey: "children_truncated") { node["child_count"] = n }
        hits.append(node)
        return hits.count < 100
    }
    emit(["app": app.localizedName ?? "", "matches": hits])

case "tree":
    requireTrust()
    let app = requireApp()
    let appEl = AXUIElementCreateApplication(app.processIdentifier)
    let maxDepth = Int(options["depth"] ?? "") ?? 40
    var roots: [[String: Any]] = []
    if flags.contains("menubar") {
        if let bar = attr(appEl, "AXExtrasMenuBar") {
            roots.append(dump(bar as! AXUIElement, id: "m", depth: 0, maxDepth: maxDepth))
        }
    } else {
        let ws = windows(appEl)
        let sel = options["window"]
        for (i, w) in ws.enumerated() {
            if let sel {
                if let n = Int(sel), n != i { continue }
                if Int(sel) == nil, !(str(w, kAXTitleAttribute) ?? "").localizedCaseInsensitiveContains(sel) { continue }
            }
            roots.append(dump(w, id: "w\(i)", depth: 0, maxDepth: maxDepth))
        }
    }
    var out: [String: Any] = ["app": app.localizedName ?? "", "pid": app.processIdentifier, "roots": roots]
    if nodeCount >= maxNodes { out["truncated"] = "hit \(maxNodes) nodes; use --window or --depth" }
    if roots.isEmpty { out["note"] = flags.contains("menubar") ? "no menubar extras" : "no windows" }
    emit(out)

case "click", "doubleclick":
    requireTrust()
    guard positional.count >= 2 else { fail("usage: axcli \(command) <id>") }
    let app = requireApp()
    let el = resolve(positional[1], app: AXUIElementCreateApplication(app.processIdentifier))
    let acts = actions(el)
    if command == "click", acts.contains(kAXPressAction) {
        let err = AXUIElementPerformAction(el, kAXPressAction as CFString)
        if err == .success { emit(["ok": true, "method": "AXPress"]); break }
    }
    guard flags.contains("mouse") else {
        fail("element has no AXPress (actions: \(acts)). Retry with --mouse to click with the real pointer.")
    }
    guard let f = frame(el) else { fail("element has no frame; cannot click") }
    activate(app)
    mouseClick(at: CGPoint(x: f.midX, y: f.midY), double: command == "doubleclick")
    emit(["ok": true, "method": command == "doubleclick" ? "mouse-double" : "mouse", "at": [Int(f.midX), Int(f.midY)]])

case "type":
    requireTrust()
    guard positional.count >= 3 else { fail("usage: axcli type <id> <text>") }
    let app = requireApp()
    let el = resolve(positional[1], app: AXUIElementCreateApplication(app.processIdentifier))
    let global = flags.contains("global")
    if global { activate(app) }
    AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    usleep(100_000)
    typeText(positional[2], pid: global ? nil : app.processIdentifier)
    usleep(100_000)
    emit(["ok": true, "value": (str(el, kAXValueAttribute) as Any?) ?? NSNull()])

case "key":
    requireTrust()
    guard positional.count >= 2 else { fail("usage: axcli key <combo>") }
    let hasApp = options["app"] != nil || ProcessInfo.processInfo.environment["AXCLI_APP"] != nil
    if flags.contains("global") || !hasApp {
        if hasApp { activate(requireApp()) }
        pressCombo(positional[1], pid: nil)
        emit(["ok": true, "target": "global"])
    } else {
        let app = requireApp()
        pressCombo(positional[1], pid: app.processIdentifier)
        emit(["ok": true, "target": app.localizedName ?? ""])
    }

case "pbimage":
    guard positional.count >= 2, let image = NSImage(contentsOfFile: positional[1]) else { fail("usage: axcli pbimage <readable image file>") }
    let pb = NSPasteboard.general
    pb.clearContents()
    guard pb.writeObjects([image]) else { fail("could not write image to pasteboard") }
    emit(["ok": true, "change_count": pb.changeCount, "size": [Int(image.size.width), Int(image.size.height)]])

case "pbinfo":
    // What is on the pasteboard now: types, image size and a hash of the image data.
    let pb = NSPasteboard.general
    var out: [String: Any] = ["change_count": pb.changeCount, "types": (pb.types ?? []).map { $0.rawValue }]
    if let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
        out["image"] = ["width": rep.pixelsWide, "height": rep.pixelsHigh]
        // Hash of the decoded pixels' PNG, so the same picture gives the same value whatever the source format.
        if let png = rep.representation(using: .png, properties: [:]) {
            var h: UInt64 = 1469598103934665603
            for b in png { h = (h ^ UInt64(b)) &* 1099511628211 }
            out["image_hash"] = String(h, radix: 16)
        }
    }
    if let text = pb.string(forType: .string) { out["text"] = String(text.prefix(200)) }
    emit(out)

case "fixture":
    guard positional.count >= 3 else { fail("usage: axcli fixture <out.png> <label> [--size WxH] [--color r,g,b]") }
    let dims = (options["size"] ?? "1200x800").split(separator: "x").compactMap { Int($0) }
    guard dims.count == 2 else { fail("--size must be WxH") }
    let rgb = (options["color"] ?? "").split(separator: ",").compactMap { Double($0) }
    let label = positional[2]
    let hue = Double(abs(label.hashValue % 360)) / 360
    let bg = rgb.count == 3 ? NSColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
        : NSColor(hue: hue, saturation: 0.45, brightness: 0.85, alpha: 1)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: dims[0], pixelsHigh: dims[1], bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { fail("bitmap failed") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    bg.setFill()
    NSRect(x: 0, y: 0, width: dims[0], height: dims[1]).fill()
    let font = NSFont.systemFont(ofSize: CGFloat(dims[1]) / 9, weight: .bold)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
    let text = NSAttributedString(string: label, attributes: attrs)
    let size = text.size()
    text.draw(at: NSPoint(x: (CGFloat(dims[0]) - size.width) / 2, y: (CGFloat(dims[1]) - size.height) / 2))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { fail("png encode failed") }
    do { try png.write(to: URL(fileURLWithPath: positional[1])) } catch { fail("write failed: \(error)") }
    emit(["ok": true, "path": positional[1], "bytes": png.count])

default:
    fail("unknown command '\(command)'")
}
