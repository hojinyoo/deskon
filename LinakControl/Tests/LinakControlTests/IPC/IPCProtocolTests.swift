// IPCProtocolTests.swift
// LinakControlTests — Verifies IPC message types, framing, and JSON encoding.

import XCTest
@testable import LinakControlKit

// MARK: - Helpers

private let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = .sortedKeys
    return e
}()

private let decoder = JSONDecoder()

private func roundTrip<T: Codable>(_ value: T) throws -> T {
    let data = try encoder.encode(value)
    return try decoder.decode(T.self, from: data)
}

private func makeStatusResult(
    connected: Bool = true,
    deskName: String? = "LINAK Desk",
    heightMM: Int? = 1105,
    heightDisplay: String? = "110.5",
    unit: String = "cm",
    presets: [PresetInfo] = [
        PresetInfo(index: 1, heightMM: 730, label: "Sit"),
        PresetInfo(index: 2, heightMM: 1105, label: "Stand"),
        PresetInfo(index: 3, heightMM: nil, label: nil),
        PresetInfo(index: 4, heightMM: nil, label: nil)
    ],
    activePreset: Int? = 2
) -> StatusResult {
    StatusResult(
        connected: connected,
        deskName: deskName,
        heightMM: heightMM,
        heightDisplay: heightDisplay,
        unit: unit,
        presets: presets,
        activePreset: activePreset
    )
}

// MARK: - IPCRequest Round-Trip

final class IPCRequestRoundTripTests: XCTestCase {

    func testGetStatusRequest_roundTrip() throws {
        let request = IPCRequest(id: "abc-123", method: .getStatus, params: nil)
        let decoded = try roundTrip(request)
        XCTAssertEqual(decoded.id, "abc-123")
        XCTAssertEqual(decoded.method, .getStatus)
        XCTAssertNil(decoded.params)
    }

    func testMoveRequest_roundTrip() throws {
        let request = IPCRequest(id: "move-001", method: .move, params: .move(direction: "up", mode: "manual"))
        let decoded = try roundTrip(request)
        XCTAssertEqual(decoded.id, "move-001")
        XCTAssertEqual(decoded.method, .move)
        guard case .move(let direction, let mode) = decoded.params else {
            return XCTFail("Expected .move params")
        }
        XCTAssertEqual(direction, "up")
        XCTAssertEqual(mode, "manual")
    }

    func testGoToRequest_roundTrip() throws {
        let request = IPCRequest(id: "goto-001", method: .goTo, params: .height(mm: 1105))
        let decoded = try roundTrip(request)
        XCTAssertEqual(decoded.method, .goTo)
        guard case .height(let mm) = decoded.params else {
            return XCTFail("Expected .height params")
        }
        XCTAssertEqual(mm, 1105)
    }

    /// Height and preset both decode from an Int, so the wrong key order would silently
    /// turn a height into a preset index.
    func testPresetRequestStillDecodesAsAPreset() throws {
        let decoded = try roundTrip(IPCRequest(id: "p", method: .goPreset, params: .preset(index: 2)))
        guard case .preset(let index) = decoded.params else {
            return XCTFail("Expected .preset params")
        }
        XCTAssertEqual(index, 2)
    }

    func testMoveRequest_nilMode_roundTrip() throws {
        let request = IPCRequest(id: "move-002", method: .move, params: .move(direction: "down", mode: nil))
        let decoded = try roundTrip(request)
        guard case .move(let direction, let mode) = decoded.params else {
            return XCTFail("Expected .move params")
        }
        XCTAssertEqual(direction, "down")
        XCTAssertNil(mode)
    }

    func testGoPresetRequest_roundTrip() throws {
        let request = IPCRequest(id: "preset-002", method: .goPreset, params: .preset(index: 2))
        let decoded = try roundTrip(request)
        XCTAssertEqual(decoded.id, "preset-002")
        XCTAssertEqual(decoded.method, .goPreset)
        guard case .preset(let index) = decoded.params else {
            return XCTFail("Expected .preset params")
        }
        XCTAssertEqual(index, 2)
    }
}

// MARK: - IPCResponse Round-Trip

final class IPCResponseRoundTripTests: XCTestCase {

    func testStatusResponse_roundTrip() throws {
        let status = makeStatusResult()
        let response = IPCResponse(id: "req-1", result: .status(status), error: nil)
        let decoded = try roundTrip(response)
        XCTAssertEqual(decoded.id, "req-1")
        XCTAssertNil(decoded.error)
        guard case .status(let s) = decoded.result else {
            return XCTFail("Expected .status result")
        }
        XCTAssertTrue(s.connected)
        XCTAssertEqual(s.deskName, "LINAK Desk")
        XCTAssertEqual(s.heightMM, 1105)
        XCTAssertEqual(s.heightDisplay, "110.5")
        XCTAssertEqual(s.unit, "cm")
        XCTAssertEqual(s.presets.count, 4)
        XCTAssertEqual(s.activePreset, 2)
        XCTAssertFalse(s.needsReference, "needsReference defaults to false")
    }

    func testStatusResponse_needsReference_roundTrip() throws {
        let status = StatusResult(connected: true, unit: "cm", needsReference: true)
        let decoded = try roundTrip(IPCResponse(id: "req-nr", result: .status(status), error: nil))
        guard case .status(let s) = decoded.result else {
            return XCTFail("Expected .status result")
        }
        XCTAssertTrue(s.needsReference, "needsReference must survive the round-trip")
    }

    func testStatusResult_missingNeedsReference_decodesFalse() throws {
        // A daemon predating the field omits needs_reference — decode must tolerate it.
        let json = #"{"connected":true,"unit":"cm","presets":[]}"#
        let decoded = try JSONDecoder().decode(StatusResult.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.needsReference, "Missing needs_reference must decode to false")
        XCTAssertNil(decoded.faultCode, "Missing fault_code must decode to nil")
    }

    func testStatusResponse_faultCode_roundTrip() throws {
        let status = StatusResult(connected: true, unit: "cm", needsReference: true, faultCode: 0x1e)
        let decoded = try roundTrip(IPCResponse(id: "req-fc", result: .status(status), error: nil))
        guard case .status(let s) = decoded.result else {
            return XCTFail("Expected .status result")
        }
        XCTAssertEqual(s.faultCode, 0x1e, "fault_code must survive the round-trip")
    }

    func testOkResponse_withTargetMM_roundTrip() throws {
        let response = IPCResponse(id: "req-2", result: .ok(targetMM: 1105), error: nil)
        let decoded = try roundTrip(response)
        XCTAssertEqual(decoded.id, "req-2")
        XCTAssertNil(decoded.error)
        guard case .ok(let targetMM) = decoded.result else {
            return XCTFail("Expected .ok result")
        }
        XCTAssertEqual(targetMM, 1105)
    }

    func testOkResponse_nilTargetMM_roundTrip() throws {
        let response = IPCResponse(id: "req-3", result: .ok(targetMM: nil), error: nil)
        let decoded = try roundTrip(response)
        guard case .ok(let targetMM) = decoded.result else {
            return XCTFail("Expected .ok result")
        }
        XCTAssertNil(targetMM)
    }

    func testErrorResponse_roundTrip() throws {
        let errorPayload = IPCErrorPayload(code: 3, message: "desk not connected")
        let response = IPCResponse(id: "req-4", result: nil, error: errorPayload)
        let decoded = try roundTrip(response)
        XCTAssertEqual(decoded.id, "req-4")
        XCTAssertNil(decoded.result)
        XCTAssertEqual(decoded.error?.code, 3)
        XCTAssertEqual(decoded.error?.message, "desk not connected")
    }
}

// MARK: - IPCFraming

final class IPCFramingTests: XCTestCase {

    func testFrameThenDeframe_returnsOriginalPayload() {
        let payload = Data("hello framing".utf8)
        let framed = IPCFraming.frame(payload)
        let result = IPCFraming.deframe(framed)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.message, payload)
        XCTAssertTrue(result?.remaining.isEmpty ?? false)
    }

    func testDeframe_partialPayload_returnsNil() {
        let payload = Data(repeating: 0x41, count: 100)
        var framed = IPCFraming.frame(payload)
        framed = framed.dropLast(50)  // truncate payload
        XCTAssertNil(IPCFraming.deframe(framed))
    }

    func testDeframe_twoCompleteMessages_firstExtractedSecondInRemaining() {
        let first = Data("first".utf8)
        let second = Data("second".utf8)
        let buffer = IPCFraming.frame(first) + IPCFraming.frame(second)

        let result1 = IPCFraming.deframe(buffer)
        XCTAssertNotNil(result1)
        XCTAssertEqual(result1?.message, first)

        let result2 = result1.flatMap { IPCFraming.deframe($0.remaining) }
        XCTAssertNotNil(result2)
        XCTAssertEqual(result2?.message, second)
        XCTAssertTrue(result2?.remaining.isEmpty ?? false)
    }

    func testDeframe_bufferTooShort_returnsNil() {
        let buffer = Data([0x00, 0x00, 0x01])  // only 3 bytes — no complete length prefix
        XCTAssertNil(IPCFraming.deframe(buffer))
    }

    func testDeframe_emptyBuffer_returnsNil() {
        XCTAssertNil(IPCFraming.deframe(Data()))
    }

    func testDeframe_payloadExceedsMaxSize_returnsNil() {
        // Build a 4-byte big-endian prefix for maxPayloadSize + 1 without the payload bytes.
        let oversizedLength = IPCFraming.maxPayloadSize + 1
        let b0 = UInt8((oversizedLength >> 24) & 0xFF)
        let b1 = UInt8((oversizedLength >> 16) & 0xFF)
        let b2 = UInt8((oversizedLength >> 8) & 0xFF)
        let b3 = UInt8(oversizedLength & 0xFF)
        let buffer = Data([b0, b1, b2, b3])
        XCTAssertNil(IPCFraming.deframe(buffer))
    }

    func testFrame_producesCorrectLengthPrefix() {
        let payload = Data([0xAA, 0xBB, 0xCC])
        let framed = IPCFraming.frame(payload)
        // First 4 bytes must be 0x00 0x00 0x00 0x03 (big-endian 3)
        XCTAssertEqual(framed[0], 0x00)
        XCTAssertEqual(framed[1], 0x00)
        XCTAssertEqual(framed[2], 0x00)
        XCTAssertEqual(framed[3], 0x03)
        XCTAssertEqual(framed[4...], Data([0xAA, 0xBB, 0xCC]))
    }
}

// MARK: - IPCMethod Serialization

final class IPCMethodSerializationTests: XCTestCase {

    func testAllMethodsSerializeToCorrectStrings() throws {
        let cases: [(IPCMethod, String)] = [
            (.getStatus, "getStatus"),
            (.move, "move"),
            (.stop, "stop"),
            (.goPreset, "goPreset"),
            (.savePreset, "savePreset")
        ]
        for (method, expectedRaw) in cases {
            XCTAssertEqual(method.rawValue, expectedRaw, "Method \(method) should have rawValue '\(expectedRaw)'")
        }
    }

    func testAllMethodsRoundTripViaCodable() throws {
        let methods: [IPCMethod] = [.getStatus, .move, .stop, .goPreset, .savePreset]
        for method in methods {
            let decoded = try roundTrip(method)
            XCTAssertEqual(decoded, method)
        }
    }
}

// MARK: - IPCErrorCode Values

final class IPCErrorCodeTests: XCTestCase {

    func testErrorCodeRawValues_matchSDD() {
        XCTAssertEqual(IPCErrorCode.general.rawValue, 1)
        XCTAssertEqual(IPCErrorCode.daemonNotRunning.rawValue, 2)
        XCTAssertEqual(IPCErrorCode.notConnected.rawValue, 3)
        XCTAssertEqual(IPCErrorCode.timeout.rawValue, 5)
        XCTAssertEqual(IPCErrorCode.invalidRequest.rawValue, 10)
    }
}

// MARK: - JSON Key Convention

final class IPCJSONKeyConventionTests: XCTestCase {

    func testStatusResult_usesSnakeCaseKeys() throws {
        let status = makeStatusResult()
        let data = try encoder.encode(status)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(json["desk_name"], "Expected snake_case key 'desk_name'")
        XCTAssertNotNil(json["height_mm"], "Expected snake_case key 'height_mm'")
        XCTAssertNotNil(json["height_display"], "Expected snake_case key 'height_display'")
        XCTAssertNotNil(json["active_preset"], "Expected snake_case key 'active_preset'")
        XCTAssertNil(json["deskName"], "Unexpected camelCase key 'deskName'")
        XCTAssertNil(json["heightMM"], "Unexpected camelCase key 'heightMM'")
    }

    func testPresetInfo_usesSnakeCaseHeightKey() throws {
        let preset = PresetInfo(index: 1, heightMM: 730, label: "Sit")
        let data = try encoder.encode(preset)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(json["height_mm"], "Expected snake_case key 'height_mm'")
        XCTAssertNil(json["heightMM"], "Unexpected camelCase key 'heightMM'")
    }

    func testOkResult_usesSnakeCaseTargetKey() throws {
        let result = IPCResult.ok(targetMM: 1105)
        let data = try encoder.encode(result)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(json["target_mm"], "Expected snake_case key 'target_mm'")
        XCTAssertNil(json["targetMM"], "Unexpected camelCase key 'targetMM'")
    }
}
