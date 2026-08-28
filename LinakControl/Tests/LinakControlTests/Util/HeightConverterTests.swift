// HeightConverterTests.swift
// LinakControlTests

import XCTest
@testable import LinakControlKit

final class HeightConverterTests: XCTestCase {

    // MARK: - display(mm:unit:) — centimetres

    func testDisplayCentimetres_typicalHeight() {
        XCTAssertEqual(HeightConverter.display(mm: 1105, unit: .cm), "110.5 cm")
    }

    func testDisplayCentimetres_lowerTypicalHeight() {
        XCTAssertEqual(HeightConverter.display(mm: 737, unit: .cm), "73.7 cm")
    }

    func testDisplayCentimetres_minimumDeskHeight() {
        // ~620 mm is the lowest position on a typical LINAK DPG1C desk
        XCTAssertEqual(HeightConverter.display(mm: 620, unit: .cm), "62 cm")
    }

    func testDisplayCentimetres_maximumDeskHeight() {
        // ~1300 mm is the highest position on a typical LINAK DPG1C desk
        XCTAssertEqual(HeightConverter.display(mm: 1300, unit: .cm), "130 cm")
    }

    func testDisplayCentimetres_zeroHeight() {
        XCTAssertEqual(HeightConverter.display(mm: 0, unit: .cm), "0 cm")
    }

    func testDisplayCentimetres_oneDecimalPlace() {
        // 1001 mm → 100.1 cm — verifies exactly one decimal digit
        XCTAssertEqual(HeightConverter.display(mm: 1001, unit: .cm), "100.1 cm")
    }

    // MARK: - display(mm:unit:) — inches

    func testDisplayInches_typicalHeight() {
        XCTAssertEqual(HeightConverter.display(mm: 1105, unit: .inch), "43.5 in")
    }

    func testDisplayInches_lowerTypicalHeight() {
        // 737 / 25.4 = 29.015..., rounds to 29.0 -> fractional < 0.05, show "29 in"
        XCTAssertEqual(HeightConverter.display(mm: 737, unit: .inch), "29 in")
    }

    func testDisplayInches_minimumDeskHeight() {
        // 620 / 25.4 = 24.409…, rounds to 24.4
        XCTAssertEqual(HeightConverter.display(mm: 620, unit: .inch), "24.4 in")
    }

    func testDisplayInches_maximumDeskHeight() {
        // 1300 / 25.4 = 51.181…, rounds to 51.2
        XCTAssertEqual(HeightConverter.display(mm: 1300, unit: .inch), "51.2 in")
    }

    func testDisplayInches_zeroHeight() {
        XCTAssertEqual(HeightConverter.display(mm: 0, unit: .inch), "0 in")
    }

    // MARK: - toCentimeters / toInches — raw conversion values

    func testToCentimetres_dividesByTen() {
        XCTAssertEqual(HeightConverter.toCentimeters(1105), 110.5, accuracy: 0.001)
    }

    func testToInches_dividesByTwentyFivePointFour() {
        XCTAssertEqual(HeightConverter.toInches(1105), 43.503937, accuracy: 0.001)
    }

    func testToCentimetres_zeroIsZero() {
        XCTAssertEqual(HeightConverter.toCentimeters(0), 0.0)
    }

    func testToInches_zeroIsZero() {
        XCTAssertEqual(HeightConverter.toInches(0), 0.0)
    }

    // MARK: - millimeters(from:unit:) - typed input

    func testMillimetres_roundTripsATypedHeight() {
        XCTAssertEqual(HeightConverter.millimeters(from: 110.5, unit: .cm), 1105)
        XCTAssertEqual(HeightConverter.millimeters(from: 43.5, unit: .inch), 1105)
    }

    /// `Double(_: String)` accepts "inf" and "nan", so argument-parser hands them straight
    /// through, and `Int(_: Double)` traps on either. `deskctl goto inf` crashed here.
    func testMillimetres_refusesNonFiniteInput() {
        XCTAssertNil(HeightConverter.millimeters(from: .infinity, unit: .cm))
        XCTAssertNil(HeightConverter.millimeters(from: -.infinity, unit: .cm))
        XCTAssertNil(HeightConverter.millimeters(from: .nan, unit: .cm))
    }

    /// Same trap, other end: `Int(1e21)` is past Int.max.
    func testMillimetres_refusesInputPastInt() {
        XCTAssertNil(HeightConverter.millimeters(from: 1e20, unit: .cm))
    }
}
