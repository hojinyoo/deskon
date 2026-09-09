// Clock.swift
// LinakControlKit — Injectable clock abstraction for deterministic time control in tests.

import Foundation

// MARK: - ClockProtocol

/// An injectable clock that abstracts real time for testability.
///
/// Use `SystemClock` in production and `TestClock` in tests.
public protocol ClockProtocol: Sendable {

    /// Returns the current instant.
    func now() -> ContinuousClock.Instant

    /// Suspends for the given duration.
    ///
    /// - Throws: `CancellationError` if the enclosing task is cancelled.
    func sleep(for duration: Duration) async throws
}

// MARK: - SystemClock

/// Production clock backed by `ContinuousClock`.
public struct SystemClock: ClockProtocol {

    public init() {}

    public func now() -> ContinuousClock.Instant {
        ContinuousClock.now
    }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

// MARK: - TestClock

/// A manually-advanced clock for deterministic unit tests.
///
/// Call ``advance(by:)`` to move time forward. Any pending `sleep` calls
/// whose deadline has been reached will resume immediately.
public final class TestClock: ClockProtocol, @unchecked Sendable {

    // MARK: - Internal waiter

    private struct Waiter {
        let id: UInt64
        let deadline: ContinuousClock.Instant
        let resume: CheckedContinuation<Void, Error>
    }

    // MARK: - State (protected by lock)

    private let lock = NSLock()
    private var _now: ContinuousClock.Instant
    private var _waiters: [Waiter] = []
    private var _nextID: UInt64 = 0

    public init(startingAt instant: ContinuousClock.Instant = ContinuousClock.now) {
        _now = instant
    }

    // MARK: - ClockProtocol

    public func now() -> ContinuousClock.Instant {
        lock.withLock { _now }
    }

    public func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()

        let (deadline, waiterID): (ContinuousClock.Instant, UInt64) = lock.withLock {
            let d = _now.advanced(by: duration)
            let id = _nextID
            _nextID += 1
            return (d, id)
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    if _now >= deadline {
                        cont.resume()
                    } else {
                        _waiters.append(Waiter(id: waiterID, deadline: deadline, resume: cont))
                    }
                }
            }
        } onCancel: {
            let cont: CheckedContinuation<Void, Error>? = lock.withLock {
                guard let idx = _waiters.firstIndex(where: { $0.id == waiterID }) else { return nil }
                let c = _waiters[idx].resume
                _waiters.remove(at: idx)
                return c
            }
            cont?.resume(throwing: CancellationError())
        }
    }

    // MARK: - Test Control

    /// Number of sleeps currently parked, waiting for the clock to advance.
    ///
    /// Lets a test synchronise on *"the code under test has reached its sleep"*
    /// instead of guessing with a wall-clock delay. Advancing before a task has
    /// registered its sleep leaves that sleep parked at a deadline the advance
    /// already passed, which is the classic source of a test that passes on a
    /// quiet machine and hangs on a busy one.
    public var pendingSleepers: Int {
        lock.withLock { _waiters.count }
    }

    /// Advances the clock by `duration` and resumes any pending sleeps whose deadline has passed.
    ///
    /// - Parameter duration: Amount of time to advance.
    public func advance(by duration: Duration) {
        let toResume: [CheckedContinuation<Void, Error>] = lock.withLock {
            _now = _now.advanced(by: duration)
            let ready = _waiters.filter { $0.deadline <= _now }
            _waiters.removeAll { $0.deadline <= _now }
            return ready.map(\.resume)
        }
        for cont in toResume {
            cont.resume()
        }
    }
}
