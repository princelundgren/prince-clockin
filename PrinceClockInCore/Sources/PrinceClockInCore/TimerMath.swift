import Foundation

public enum TimerState: Equatable, Sendable {
    case ok(remaining: TimeInterval)
    /// Within the warning lead time, and not yet expired.
    case expiring(remaining: TimeInterval)
    case expired
    /// No login time or no session length is known.
    case unknown
}

/// Why Set Timer refused a time. Each `message` is the copy the form shows.
public enum TimerError: Error, Equatable, Sendable {
    /// An Expires In of zero or less, or a Logged In At a session length or more ago.
    case wouldAlreadyBeExpired
    /// A Logged In At after now.
    case inFuture
    /// An Expires In longer than the session length.
    case longerThanSessionLength

    public var message: String {
        switch self {
        case .wouldAlreadyBeExpired: "That login would already have expired"
        case .inFuture: "That time is in the future"
        case .longerThanSessionLength: "That's longer than the session length"
        }
    }
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

/// Whether the login is invalidated because its AWS session was logged out, for "Logged out". With
/// no stored reason, an AWS login counts as logged out, since a logout was its only cause before
/// the reason was stored.
public func isLoggedOut(_ login: Login) -> Bool {
    guard isInvalidated(login) else { return false }
    switch login.invalidationReason {
    case .loggedOut: return true
    case .foundInvalid: return false
    case nil:
        if case .awsSSOSession = login.kind { return true }
        return false
    }
}

/// Whether a Databricks workspace login's timer has run out while its last check, made at or after
/// that expiry, found it valid. A new login time, a longer session or a later check that isn't
/// valid ends it.
public func isStillValid(_ login: Login, now: Date) -> Bool {
    guard case .databricksProfile(_, accountLevel: false) = login.kind, !isInvalidated(login),
          let expiry = expiry(of: login), expiry <= now,
          let check = login.lastDatabricksCheck
    else { return false }
    return check.result == .valid && check.at >= expiry
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

/// The menu bar's text: which login is running ("2/3") while a batch runs, else `status`'s text.
public func menuBarText(_ status: MenuBarStatus, batch: BatchProgress?) -> String {
    batch.map { "\($0.position)/\($0.total)" } ?? status.text
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
