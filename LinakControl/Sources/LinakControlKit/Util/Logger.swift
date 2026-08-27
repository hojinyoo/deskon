// Logger.swift
// LinakControlKit -- File logging for diagnostics (all build configurations).

import Foundation

// MARK: - File logger

/// Appends timestamped lines to ~/Library/Logs/LinakControl/debug.log.
///
/// All writes are serialised on a dedicated queue. The log file is created
/// automatically on first write and truncated at 1 MB (rolling) to prevent
/// unbounded growth. ``debug(_:category:)`` is active in release builds so
/// installed apps capture diagnostics; ``trace(_:category:)`` stays DEBUG-only
/// for high-frequency output. The log persists across app restarts — it is not
/// reset at launch — so an intermittent fault can be captured after the fact.
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
    /// The 1 MB rolling cap keeps growth bounded, so keep this to meaningful
    /// events; use ``trace(_:category:)`` for high-frequency per-tick output.
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

    /// Serialises and appends one line to the log file, applying the rolling cap.
    private static func append(_ text: String, category: String) {
        let ts = dateFormatter.string(from: Date())
        let line = "[\(ts)] [\(category)] \(text)\n"

        queue.async {
            guard let url = logURL else { return }
            let handle = openHandleIfNeeded(url: url)
            guard let handle else { return }
            let size = handle.seekToEndOfFile()
            if size > maxBytes {
                handle.truncateFile(atOffset: 0)
                handle.seek(toFileOffset: 0)
            }
            handle.write(Data(line.utf8))
        }
    }

    /// Truncates the log file. Call at app launch for a clean session.
    public static func reset() {
        #if DEBUG
        queue.async {
            guard let url = logURL else { return }
            fileHandle?.closeFile()
            fileHandle = nil
            try? Data().write(to: url, options: .atomic)
        }
        #endif
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
