// FileLogRotationTests.swift
// LinakControlTests — Verifies the log rotation policy (issue #9): filling the
// 1 MB cap must preserve the previous megabyte in debug.log.1 rather than
// wiping the file, which is what the code comments and user docs promised all
// along.
//
// Exercises FileLog.rotateFile(at:) against a temporary directory — the
// FileLog singleton itself writes to the real ~/Library/Logs and must not be
// driven from tests.

import XCTest
@testable import LinakControlKit

final class FileLogRotationTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("filelog-rotation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private func log() -> URL { dir.appendingPathComponent("debug.log") }
    private func rolled() -> URL { dir.appendingPathComponent("debug.log.1") }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// The whole point of #9: history survives the cap instead of vanishing.
    func testRotationPreservesTheFullLogAsDotOne() throws {
        try write("first session\n", to: log())

        FileLog.rotateFile(at: log())

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: log().path),
            "The full log must be moved aside, leaving room for a fresh one"
        )
        XCTAssertEqual(
            try read(rolled()), "first session\n",
            "Rotation must preserve the contents, not truncate them"
        )
    }

    /// Only one rotated file is kept — the docs say so explicitly, because it
    /// is what bounds total growth to ~2 MB.
    func testSecondRotationReplacesThePreviousRotatedFile() throws {
        try write("oldest\n", to: log())
        FileLog.rotateFile(at: log())

        try write("newer\n", to: log())
        FileLog.rotateFile(at: log())

        XCTAssertEqual(
            try read(rolled()), "newer\n",
            "The second rotation must replace debug.log.1, not fail against the existing file"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: log().path),
            "The rotated-away log must not linger"
        )
    }

    /// Rotating before anything was ever logged must not throw or create files.
    func testRotationWithNoExistingLogIsANoOp() throws {
        FileLog.rotateFile(at: log())

        XCTAssertFalse(FileManager.default.fileExists(atPath: log().path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rolled().path))
    }
}
