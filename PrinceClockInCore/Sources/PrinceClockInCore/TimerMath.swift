import Foundation

public enum TimerState: Equatable, Sendable {
    case ok(remaining: TimeInterval)
    /// Within the warning lead time, and not yet expired.
    case expiring(remaining: TimeInterval)
    case expired
    /// No login time or no session length is known.
    case unknown
}

public enum TimerError: Error, Equatable, Sendable {
    case expiryInPast
}

/// The login time plus the session length, or `nil` when either is unknown.
public func expiry(of login: Login) -> Date? {
    guard let loginTime = login.loginTime, let sessionLength = login.sessionLength else { return nil }
    return loginTime.addingTimeInterval(sessionLength)
}

/// Whether the login was found invalid at or after its last login time.
func isInvalidated(_ login: Login) -> Bool {
    guard let invalidatedAt = login.invalidatedAt else { return false }
    return (login.loginTime ?? .distantPast) <= invalidatedAt
}

/// Computed from absolute times only, so it is right after sleep or a clock change.
/// An invalidated login is `.expired` until a login newer than `invalidatedAt` is recorded.
public func timerState(for login: Login, now: Date, leadTime: TimeInterval) -> TimerState {
    if isInvalidated(login) { return .expired }
    guard let expiry = expiry(of: login) else { return .unknown }
    let remaining = expiry.timeIntervalSince(now)
    if remaining <= 0 { return .expired }
    return remaining <= leadTime ? .expiring(remaining: remaining) : .ok(remaining: remaining)
}

/// Records that the login expires at `expiresAt` (rounded down to whole seconds) and clears
/// `invalidatedAt`, since the user is stating the login is valid.
///
/// With a session length, the login time is derived from it. Without one, the login time is `now`
/// and the length is the whole seconds until `expiresAt`.
/// - Throws: `TimerError.expiryInPast` when the rounded `expiresAt` is not after `now`.
public func setExpiry(_ login: inout Login, expiresAt: Date, now: Date) throws {
    let expiresAt = expiresAt.wholeSeconds
    guard expiresAt > now else { throw TimerError.expiryInPast }
    if let sessionLength = login.sessionLength {
        login.loginTime = expiresAt.addingTimeInterval(-sessionLength)
    } else {
        let loginTime = now.wholeSeconds
        login.loginTime = loginTime
        login.sessionLength = expiresAt.timeIntervalSince(loginTime)
    }
    login.invalidatedAt = nil
}

public enum Severity: Equatable, Sendable { case normal, expiring, expired }

public struct MenuBarStatus: Equatable, Sendable {
    public let text: String
    public let severity: Severity

    public init(text: String, severity: Severity) {
        self.text = text
        self.severity = severity
    }
}

/// The text is the time left on the soonest-expiring login that hasn't expired, rounded down:
/// `2d03h` from 24 hours up, `2h05`, `45m`, `<1m`, or `—` when no login has a known, unexpired
/// timer. The severity is `.expired` if any login has expired, else `.expiring` if any is inside
/// the lead time.
public func menuBarStatus(_ logins: [Login], now: Date, leadTime: TimeInterval) -> MenuBarStatus {
    var soonest: TimeInterval?
    var severity = Severity.normal
    for login in logins {
        switch timerState(for: login, now: now, leadTime: leadTime) {
        case .expired:
            severity = .expired
        case .expiring(let remaining):
            if severity == .normal { severity = .expiring }
            soonest = min(soonest ?? remaining, remaining)
        case .ok(let remaining):
            soonest = min(soonest ?? remaining, remaining)
        case .unknown:
            break
        }
    }
    return MenuBarStatus(text: soonest.map(remainingText) ?? "—", severity: severity)
}

/// A login row's description of `state`: "2h14 left", "Expiring, 25m left", "Expired" or
/// "No known expiry", with the time left formatted as in the menu bar.
public func rowStateText(_ state: TimerState) -> String {
    switch state {
    case .ok(let remaining): "\(remainingText(remaining)) left"
    case .expiring(let remaining): "Expiring, \(remainingText(remaining)) left"
    case .expired: "Expired"
    case .unknown: "No known expiry"
    }
}

func remainingText(_ remaining: TimeInterval) -> String {
    let minutes = Int(remaining / 60)
    if minutes >= 24 * 60 {
        return "\(minutes / (24 * 60))d\(twoDigits(minutes % (24 * 60) / 60))h"
    }
    if minutes >= 60 {
        return "\(minutes / 60)h\(twoDigits(minutes % 60))"
    }
    return minutes >= 1 ? "\(minutes)m" : "<1m"
}

private func twoDigits(_ value: Int) -> String {
    value < 10 ? "0\(value)" : "\(value)"
}
