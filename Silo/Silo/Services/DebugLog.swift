import Foundation

/// Captures idevice's own protocol-level tracing (DeviceLink message
/// exchange, mobilebackup2 internals) to a file.
///
/// Console.app can show BackupAgent's *system* logs but never this
/// process's own tracing output — and the reverse holds too, this process
/// can never read BackupAgent's logs (different sandbox). This exposes the
/// half we actually control, so a failed attempt can be inspected inside
/// Silo itself instead of needing a Mac and Console.app.
enum DebugLog {
    static let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("silo-idevice-debug.log")
    /// Last launch's log, kept so a run that ends in a crash can still be
    /// read afterwards. Without this the relaunch truncates the only copy
    /// of exactly the evidence a crash needs.
    static let previousURL = FileManager.default.temporaryDirectory.appendingPathComponent("silo-idevice-previous.log")
    /// Silo's own step markers, separate from idevice's tracing. The Rust
    /// logger owns its file handle, so this process appends its own trail
    /// beside it rather than trying to interleave.
    static let notesURL = FileManager.default.temporaryDirectory.appendingPathComponent("silo-steps.log")
    static let previousNotesURL = FileManager.default.temporaryDirectory.appendingPathComponent("silo-steps-previous.log")

    /// Call once at app launch. Safe to call more than once — only the
    /// first call takes effect (idevice_init_logger is itself call-once).
    static func start() {
        // Preserve the previous launch before the Rust logger truncates it.
        rotate(fileURL, to: previousURL)
        rotate(notesURL, to: previousNotesURL)
        FileManager.default.createFile(atPath: notesURL.path, contents: nil)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        fileURL.path.withCString { path in
            // Debug, not Trace: trace level logs every single socket push,
            // which during an actual transfer grows the file by megabytes a
            // minute and makes reading it back for display crawl. Every
            // DeviceLink message and protocol step is at debug.
            _ = idevice_init_logger(Debug, Debug, UnsafeMutablePointer(mutating: path))
        }
    }

    private static func rotate(_ from: URL, to destination: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: from.path) else { return }
        try? fm.removeItem(at: destination)
        try? fm.moveItem(at: from, to: destination)
    }

    /// Appends one step marker. Deliberately unbuffered and reopened per
    /// call: the whole point is that the line survives an abort happening
    /// on the very next instruction.
    static func note(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(message)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: notesURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: notesURL)
        }
    }

    /// The step trail and protocol log from the launch before this one —
    /// what to read after a crash.
    static func previousRun() -> String {
        let steps = (try? String(contentsOf: previousNotesURL, encoding: .utf8)) ?? ""
        let protocolLog = (try? String(contentsOf: previousURL, encoding: .utf8)) ?? ""
        if steps.isEmpty && protocolLog.isEmpty { return "" }
        let tail = protocolLog.count > 20_000 ? "…\n" + String(protocolLog.suffix(20_000)) : protocolLog
        return "=== PREVIOUS RUN STEPS ===\n\(steps)\n=== PROTOCOL ===\n\(tail)"
    }

    /// Byte offset marking "now" — pair with `tail(from:)` to read only
    /// what a specific attempt logged, not everything since launch.
    static func currentOffset() -> UInt64 {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return 0 }
        defer { try? handle.close() }
        return (try? handle.seekToEnd()) ?? 0
    }

    /// Everything logged since `offset`, keeping at most `maxBytes` from the
    /// end. A backup in flight writes continuously, so an uncapped read
    /// grows without bound and stutters the UI that displays it; the recent
    /// end is the part worth looking at anyway.
    static func tail(from offset: UInt64, maxBytes: UInt64 = 512_000) -> String {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return "" }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        guard end > offset else { return "" }
        let truncated = end - offset > maxBytes
        try? handle.seek(toOffset: truncated ? end - maxBytes : offset)
        guard let data = try? handle.readToEnd() else { return "" }
        let text = String(decoding: data, as: UTF8.self)
        return truncated ? "…(showing only the end of the log)\n" + text : text
    }
}
