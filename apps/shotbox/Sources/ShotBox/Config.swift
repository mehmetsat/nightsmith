import Foundation

/// Folders the app reads and writes. Environment overrides exist so QA never touches real screenshots.
enum Config {
    private static let env = ProcessInfo.processInfo.environment

    /// Where images, thumbnails and the SQLite database live.
    static var dataDir: URL {
        if let path = env["SHOTBOX_DATA_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShotBox", isDirectory: true)
    }

    /// The folder macOS saves screenshots to. Read-only: we never write the screencapture defaults.
    static var watchDir: URL {
        if let path = env["SHOTBOX_WATCH_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        var path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") ?? ""
        if path.isEmpty { path = NSHomeDirectory() + "/Desktop" }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }
}
