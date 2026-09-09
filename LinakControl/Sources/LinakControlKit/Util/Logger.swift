// Logger.swift
// LinakControlKit -- File logging for diagnostics (all build configurations).

import Foundation

// MARK: - File logger

/// Appends timestamped lines to ~/Library/Logs/LinakControl/debug.log.
///
/// All writes are serialised on a dedicated queue. The log file is created
/// automatically on first write. At 1 MB it is **rotated**: the full file
/// becomes `debug.log.1` (replacing any previous one) and logging continues in
/// a fresh `debug.log`, so between 1 MB and 2 MB of history always survives.
/// ``debug(_:category:)`` is active in release builds so installed apps capture
/// diagnostics; ``trace(_:category:)`` stays DEBUG-only for high-frequency
/// output. The log persists across app restarts — it is not reset at launch —
/// so an intermittent fault can be captured after the fact.
public enum FileLog {

    private static let queue = DispatchQueue(label: "com.linakcontrol.filelog")
    private static let maxBytes = 1_000_000
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Where lines are appended. Internal so tests can assert they are not aimed at the
    /// installed app's log.
    static let logURL: URL? = {
        // A test run must never append to the log a running app is writing: diagnosis on
        // this project is done by reading that file, and mock handshake values interleaved
        // with live desk telemetry read as real desk behaviour.
        guard !isRunningTests else {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("LinakControlTests-\(ProcessInfo.processInfo.processIdentifier).log")
        }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/LinakControl", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir.appendingPathComponent("debug.log")
    }()

    static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    /// Persistent file handle — opened once, reused for all writes.
    /// Avoids file-descriptor churn at ~10Hz during desk movement.
    private static var fileHandle: FileHandle?

    /// Write a single event-level log line. Active in **all** build
    /// configurations (release included) so diagnostics — such as raw desk
    /// status packets around an E16 fault — are captured on installed builds.
    /// Rotation keeps growth bounded, so keep this to meaningful events; use
    /// ``trace(_:category:)`` for high-frequency per-tick output, which would
    /// otherwise push the events worth keeping into `debug.log.1` and out.
    public static func debug(_ message: @autoclosure () -> String, category: String = "general") {
        append(message(), category: category)
    }

    /// Write a high-frequency (e.g. per-tick, ~10 Hz) trace line. DEBUG-only,
    /// so it never floods the bounded release log and rolls out recent events.
    public static func trace(_ message: @autoclosure () -> String, category: String = "general") {
        #if DEBUG
        append(message(), category: category)
        #endif
    }

    /// Serialises and appends one line to the log file, rotating at the cap.
    private static func append(_ text: String, category: String) {
        let ts = dateFormatter.string(from: Date())
        let line = "[\(ts)] [\(category)] \(text)\n"

        queue.async {
            guard let url = logURL else { return }
            guard var handle = openHandleIfNeeded(url: url) else { return }
            if handle.seekToEndOfFile() > maxBytes {
                guard let rotated = rotate(url: url) else { return }
                handle = rotated
            }
            handle.write(Data(line.utf8))
        }
    }

    /// Closes the current handle, rotates the file, and opens a fresh one.
    ///
    /// Must be called on `queue`, which serialises it against every write.
    ///
    /// - Returns: a handle on the fresh file, or nil if it could not be opened.
    private static func rotate(url: URL) -> FileHandle? {
        fileHandle?.closeFile()
        fileHandle = nil
        rotateFile(at: url)
        return openHandleIfNeeded(url: url)
    }

    /// Renames the log at `url` to `<url>.1`, replacing any previous rotated
    /// file. Keeps at least one full cap's worth of history — the point of the
    /// log is capturing an intermittent fault after it happens, which
    /// truncating the file in place defeated.
    ///
    /// Split out from ``rotate(url:)`` as a plain filesystem operation with no
    /// handle state, so it can be exercised against a temporary directory
    /// instead of the real log.
    static func rotateFile(at url: URL) {
        let rolled = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: rolled)
        try? FileManager.default.moveItem(at: url, to: rolled)
    }

    /// Opens or returns the existing persistent file handle.
    /// Creates the file with 0600 permissions if it doesn't exist.
    private static func openHandleIfNeeded(url: URL) -> FileHandle? {
        if let handle = fileHandle { return handle }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(
                atPath: url.path, contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        fileHandle = try? FileHandle(forWritingTo: url)
        return fileHandle
    }
}
