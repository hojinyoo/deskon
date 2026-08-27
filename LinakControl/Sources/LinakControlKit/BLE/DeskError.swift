// DeskError.swift
// LinakControlKit — Errors surfaced by desk-level operations.

import Foundation

// MARK: - DeskError

/// Errors thrown by desk protocol operations including handshake, movement, and preset recall.
public enum DeskError: Error, Sendable {

    /// The output mask response did not match the expected value `Data([0x01])`.
    case unexpectedMaskValue(Data)

    /// A DPG query did not receive a notification response within the timeout window.
    case handshakeTimeout

    /// The operation requires an active BLE connection, but none exists.
    case notConnected

    /// The requested preset slot has no height stored.
    case presetNotSet(index: Int)

    /// The target height in mm is outside the safe command range (600...1350 mm).
    case targetOutOfRange(Int)

    /// A DPG response could not be parsed into the expected format.
    case invalidResponse

    /// The desk did not respond to wake-up commands after the maximum number of retries.
    case wakeUpFailed

    /// Bluetooth cannot be used at all: unsupported hardware, or the app is not authorised.
    case bluetoothUnavailable(BLEState)
}
