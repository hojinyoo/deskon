// FileLogDestinationTests.swift
// LinakControlTests - The test suite must not append to the log a running app writes.

import XCTest
@testable import LinakControlKit

final class FileLogDestinationTests: XCTestCase {

    private var appLogPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/LinakControl/debug.log").path
    }

    func testTestRunsDoNotWriteToTheAppLog() {
        XCTAssertNotEqual(
            FileLog.logURL?.path, appLogPath,
            "a test run interleaves mock handshake values with live desk telemetry"
        )
    }

    func testTestRunsAreDetected() {
        XCTAssertTrue(FileLog.isRunningTests)
    }

    func testTheLogStillWritesSomewhere() throws {
        let url = try XCTUnwrap(FileLog.logURL)
        FileLog.debug("destination check", category: "test")

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8), text.contains("destination check") {
                return
            }
            usleep(20_000)
        }
        XCTFail("the redirected log never received the line")
    }
}
