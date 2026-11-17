import Foundation
import PrinceClockInCore

/// Parses an ISO 8601 fixture such as `2026-11-17T09:00:00Z`; a malformed fixture fails the test run.
func at(_ iso: String) -> Date {
    guard let date = try? Date(iso, strategy: .iso8601) else {
        preconditionFailure("bad fixture date \(iso)")
    }
    return date
}

/// A login whose timer ends `remaining` seconds after `now`, with an 8 hour session.
func login(remaining: TimeInterval, now: Date, name: String = "dev") -> Login {
    let length: TimeInterval = 8 * 3600
    return Login(
        displayName: name, kind: .awsSSOSession(name: name), sessionLength: length,
        loginTime: now.addingTimeInterval(remaining - length))
}

/// Holds a test's async step until the test opens it.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
