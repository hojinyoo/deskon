// FormatterTests.swift
// LinakControlTests — Tests CLIFormatter error message and exit code mapping.

import XCTest
@testable import LinakControlKit

// MARK: - Plain Text Formatting

final class CLIFormatterPlainTests: XCTestCase {

    func testDaemonNotRunning_plainText_containsHint() {
        let (msg, code) = CLIFormatter.formatError(.daemonNotRunning, json: false)
        XCTAssertTrue(msg.contains("daemon not running"), "message should mention daemon not running, got: \(msg)")
        XCTAssertTrue(msg.contains("Deskon.app"), "message should hint to start the app, got: \(msg)")
        XCTAssertEqual(code, .daemonNotRunning)
        XCTAssertEqual(code.rawValue, 2)
    }

    func testConnectionFailed_plainText_containsDetail() {
        let (msg, code) = CLIFormatter.formatError(.connectionFailed("timed out"), json: false)
        XCTAssertTrue(msg.contains("connection failed"), "message should mention connection failed, got: \(msg)")
        XCTAssertTrue(msg.contains("timed out"), "message should include detail, got: \(msg)")
        XCTAssertEqual(code, .general)
        XCTAssertEqual(code.rawValue, 1)
    }

    func testInvalidResponse_plainText_describesError() {
        let (msg, code) = CLIFormatter.formatError(.invalidResponse, json: false)
        XCTAssertTrue(msg.contains("invalid response"), "message should describe invalid response, got: \(msg)")
        XCTAssertEqual(code, .general)
    }

    func testServerError_notConnected_plainText_exitCode3() {
        let (msg, code) = CLIFormatter.formatError(.serverError(code: 3, message: "desk not connected"), json: false)
        XCTAssertTrue(msg.contains("desk not connected"), "message should include server message, got: \(msg)")
        XCTAssertEqual(code, .notConnected)
        XCTAssertEqual(code.rawValue, 3)
    }

    func testServerError_timeout_plainText_exitCode5() {
        let (msg, code) = CLIFormatter.formatError(.serverError(code: 5, message: "operation timed out"), json: false)
        XCTAssertTrue(msg.contains("operation timed out"), "message should include server message, got: \(msg)")
        XCTAssertEqual(code, .timeout)
        XCTAssertEqual(code.rawValue, 5)
    }

    func testServerError_unknownCode_plainText_generalExit() {
        let (msg, code) = CLIFormatter.formatError(.serverError(code: 99, message: "something went wrong"), json: false)
        XCTAssertTrue(msg.contains("something went wrong"), "message should include server message, got: \(msg)")
        XCTAssertEqual(code, .general)
    }
}

// MARK: - JSON Formatting

final class CLIFormatterJSONTests: XCTestCase {

    func testDaemonNotRunning_json_isValidJSON_withCode2() {
        let (msg, code) = CLIFormatter.formatError(.daemonNotRunning, json: true)
        assertValidJSON(msg)
        assertJSONContains(msg, key: "error", value: 2)
        XCTAssertEqual(code, .daemonNotRunning)
    }

    func testConnectionFailed_json_isValidJSON_withCode1() {
        let (msg, code) = CLIFormatter.formatError(.connectionFailed("refused"), json: true)
        assertValidJSON(msg)
        assertJSONContains(msg, key: "error", value: 1)
        XCTAssertEqual(code, .general)
    }

    func testInvalidResponse_json_isValidJSON_withCode1() {
        let (msg, code) = CLIFormatter.formatError(.invalidResponse, json: true)
        assertValidJSON(msg)
        assertJSONContains(msg, key: "error", value: 1)
        XCTAssertEqual(code, .general)
    }

    func testServerError_notConnected_json_isValidJSON_withCode3() {
        let (msg, code) = CLIFormatter.formatError(.serverError(code: 3, message: "desk not connected"), json: true)
        assertValidJSON(msg)
        assertJSONContains(msg, key: "error", value: 3)
        XCTAssertTrue(msg.contains("desk not connected"), "JSON should contain server message, got: \(msg)")
        XCTAssertEqual(code, .notConnected)
    }

    func testServerError_timeout_json_isValidJSON_withCode5() {
        let (msg, code) = CLIFormatter.formatError(.serverError(code: 5, message: "timed out"), json: true)
        assertValidJSON(msg)
        assertJSONContains(msg, key: "error", value: 5)
        XCTAssertEqual(code, .timeout)
    }

    // MARK: - Assertion Helpers

    private func assertValidJSON(_ string: String, file: StaticString = #file, line: UInt = #line) {
        guard let data = string.data(using: .utf8) else {
            XCTFail("Could not encode string as UTF-8", file: file, line: line)
            return
        }
        XCTAssertNoThrow(
            try JSONSerialization.jsonObject(with: data),
            "Expected valid JSON but got: \(string)",
            file: file, line: line
        )
    }

    private func assertJSONContains(
        _ string: String,
        key: String,
        value: Int,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard let data = string.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let actual = obj[key] as? Int else {
            XCTFail("Could not parse '\(key)' as Int from JSON: \(string)", file: file, line: line)
            return
        }
        XCTAssertEqual(actual, value, "Expected \(key)=\(value), got \(actual)", file: file, line: line)
    }
}

// MARK: - Exit Code Constants

final class CLIExitCodeTests: XCTestCase {

    func testExitCodeRawValues_matchSDD() {
        XCTAssertEqual(CLIExitCode.success.rawValue, 0)
        XCTAssertEqual(CLIExitCode.general.rawValue, 1)
        XCTAssertEqual(CLIExitCode.daemonNotRunning.rawValue, 2)
        XCTAssertEqual(CLIExitCode.notConnected.rawValue, 3)
        XCTAssertEqual(CLIExitCode.timeout.rawValue, 5)
    }
}
