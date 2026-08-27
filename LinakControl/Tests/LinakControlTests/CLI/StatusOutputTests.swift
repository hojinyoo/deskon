// StatusOutputTests.swift
// LinakControlTests — Verifies the plain-text strings printed by `deskctl status` and
// `deskctl height`. The units come from HeightConverter only; nothing appends a second one.

import XCTest
@testable import LinakControlKit

// MARK: - Helpers

private func makeStatus(
    unit: HeightUnit,
    heightMM: Int? = 701,
    presets: [PresetInfo] = [],
    activePreset: Int? = nil
) -> StatusResult {
    StatusResult(
        connected: true,
        deskName: "DESK 3424",
        heightMM: heightMM,
        heightDisplay: heightMM.map { HeightConverter.display(mm: $0, unit: unit) },
        unit: unit.rawValue,
        presets: presets,
        activePreset: activePreset
    )
}

private let fourPresets = [
    PresetInfo(index: 1, heightMM: 701),
    PresetInfo(index: 2),
    PresetInfo(index: 3),
    PresetInfo(index: 4),
]

// MARK: - deskctl height

final class CLIHeightOutputTests: XCTestCase {

    func testHeightPrintsUnitExactlyOnce() {
        XCTAssertEqual(CLIFormatter.formatHeight(makeStatus(unit: .cm)), "70.1 cm")
    }

    func testHeightUsesConfiguredInchUnit() {
        XCTAssertEqual(CLIFormatter.formatHeight(makeStatus(unit: .inch)), "27.6 in")
    }

    func testHeightWithoutReadingPrintsUnknown() {
        XCTAssertEqual(CLIFormatter.formatHeight(makeStatus(unit: .cm, heightMM: nil)), "unknown")
    }
}

// MARK: - deskctl status

final class CLIStatusOutputTests: XCTestCase {

    func testStatusTableInCentimetres() {
        let output = CLIFormatter.formatStatus(makeStatus(unit: .cm, presets: fourPresets))
        XCTAssertEqual(output, """
        LinakControl Daemon
          Connection: connected
          Desk:       DESK 3424
          Height:     70.1 cm
          Presets:    1=70.1 cm  2=unset  3=unset  4=unset
        """)
    }

    func testStatusTableInInches() {
        let output = CLIFormatter.formatStatus(makeStatus(unit: .inch, presets: fourPresets))
        XCTAssertEqual(output, """
        LinakControl Daemon
          Connection: connected
          Desk:       DESK 3424
          Height:     27.6 in
          Presets:    1=27.6 in  2=unset  3=unset  4=unset
        """)
    }

    func testStatusNeverDoublesTheUnitSuffix() {
        for unit in [HeightUnit.cm, .inch] {
            let output = CLIFormatter.formatStatus(makeStatus(unit: unit, presets: fourPresets))
            XCTAssertFalse(output.contains("cm cm"), "duplicated cm suffix in: \(output)")
            XCTAssertFalse(output.contains("in in"), "duplicated in suffix in: \(output)")
            XCTAssertFalse(output.contains("?"), "unset preset must not render as '?': \(output)")
        }
    }

    func testActivePresetIsMarkedAndLabelsAreKept() {
        let presets = [
            PresetInfo(index: 1, heightMM: 701, label: "Sitting"),
            PresetInfo(index: 2, heightMM: 1105),
        ]
        let output = CLIFormatter.formatStatus(makeStatus(unit: .cm, presets: presets, activePreset: 2))
        XCTAssertTrue(
            output.contains("  Presets:    1=70.1 cm Sitting  2=110.5 cm*"),
            "unexpected presets line in: \(output)"
        )
    }

    func testStatusOmitsPresetsLineWhenNoneReported() {
        let output = CLIFormatter.formatStatus(makeStatus(unit: .cm))
        XCTAssertFalse(output.contains("Presets:"), "presets line should be omitted, got: \(output)")
    }
}
