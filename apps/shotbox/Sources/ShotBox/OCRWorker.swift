import Foundation

/// Vision keeps a few hundred MB of working memory for as long as the process lives. Recognition therefore runs in a
/// helper process (this same executable, started with --ocr-worker) that is replaced every few dozen images, so the
/// app itself stays small however many captures arrive.
final class OCRClient {
    static let shared = OCRClient()

    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var served = 0
    /// Images one helper reads before it is replaced.
    private static let recycleAfter = 12

    /// Text and word boxes for the image file, or nil when the helper could not read it.
    func recognize(_ url: URL) -> (text: String, boxes: String)? {
        lock.lock()
        defer { lock.unlock() }
        for attempt in 0..<2 {
            guard ensureWorker(), let input, let output else { return nil }
            guard let line = (url.path + "\n").data(using: .utf8) else { return nil }
            do { try input.write(contentsOf: line) } catch { stop(); continue }
            guard let reply = readLine(from: output) else {
                stop()
                if attempt == 0 { continue }
                return nil
            }
            served += 1
            if served >= Self.recycleAfter { stop() } else { scheduleIdleStop() }
            guard let obj = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
                  obj["failed"] == nil, let text = obj["text"] as? String else { return nil }
            return (text, obj["boxes"] as? String ?? "")
        }
        return nil
    }

    /// A helper with nothing to read for a while goes away, taking its memory with it.
    private var idleWork: DispatchWorkItem?
    private func scheduleIdleStop() {
        idleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.lock.try() else { return }
            defer { self.lock.unlock() }
            self.stop()
        }
        idleWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func readLine(from handle: FileHandle) -> Data? {
        while true {
            if let nl = buffer.firstIndex(of: 10) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                return line
            }
            let chunk = handle.availableData
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
        }
    }

    private func ensureWorker() -> Bool {
        if let process, process.isRunning { return true }
        stop()
        guard let exe = Bundle.main.executableURL else { return false }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--ocr-worker"]
        let toChild = Pipe(), fromChild = Pipe()
        p.standardInput = toChild
        p.standardOutput = fromChild
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        process = p
        input = toChild.fileHandleForWriting
        output = fromChild.fileHandleForReading
        buffer = Data()
        served = 0
        return true
    }

    private func stop() {
        try? input?.close()
        if let process, process.isRunning { process.terminate() }
        process = nil
        input = nil
        output = nil
    }

    /// The helper's whole life: read a path per line, answer with one line of JSON.
    static func runWorker() -> Never {
        while let path = Swift.readLine() {
            var reply: [String: Any] = ["text": "", "failed": true]
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let read = Engine.recognizeText(data) {
                reply = ["text": read.text, "boxes": read.boxes]
            }
            if let out = try? JSONSerialization.data(withJSONObject: reply), let s = String(data: out, encoding: .utf8) {
                print(s)
                fflush(stdout)
            }
        }
        exit(0)
    }
}
