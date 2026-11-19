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

/// Whether the login is due: expiring or expired, and not still valid. An unknown timer isn't due.
func isDue(_ login: Login, now: Date, leadTime: TimeInterval) -> Bool {
    switch timerState(for: login, now: now, leadTime: leadTime) {
    case .expiring: true
    case .expired: !isStillValid(login, now: now)
    case .ok, .unknown: false
    }
}

/// When an expired login stopped working: its expiry, or when it was invalidated if that came
/// first. `nil` for a login that has neither.
func expiredAt(_ login: Login) -> Date? {
    let timerExpiry = expiry(of: login)
    guard isInvalidated(login), let invalidatedAt = login.invalidatedAt else { return timerExpiry }
    return min(timerExpiry ?? invalidatedAt, invalidatedAt)
}

/// What the menu bar label shows. When several rows apply, the first case listed wins. A row about
/// one login carries its id, so the label's time and the login it names always agree.
public enum MenuBarStatus: Equatable, Sendable {
    case loggingIn(BatchProgress)
    /// A failure, or a failed save, as the caller reports it in `hasFailure`.
    case failure
    /// The login that expired first.
    case expired(id: UUID)
    /// The soonest-expiring login.
    case expiring(id: UUID, remaining: TimeInterval)
    /// The login with the soonest future expiry.
    case ok(id: UUID, remaining: TimeInterval)
    /// No login has time left, is expiring or has expired, leaving out the still valid.
    case noTimer
}

/// The menu bar's row for `logins` at `now`. A still valid login is skipped in every row. An
/// expired login counts from when it expired, an invalidated one from when it was invalidated if
/// that came first. Ties go to the login stored first.
public func menuBarStatus(
    _ logins: [Login], now: Date, leadTime: TimeInterval, batch: BatchProgress?, hasFailure: Bool
) -> MenuBarStatus {
    if let batch { return .loggingIn(batch) }
    if hasFailure { return .failure }
    var expired: [(id: UUID, key: Date)] = []
    var expiring: [(id: UUID, key: TimeInterval)] = []
    var ok: [(id: UUID, key: TimeInterval)] = []
    for login in logins where !isStillValid(login, now: now) {
        switch timerState(for: login, now: now, leadTime: leadTime) {
        case .expired: expired.append((login.id, expiredAt(login) ?? now))
        case .expiring(let remaining): expiring.append((login.id, remaining))
        case .ok(let remaining): ok.append((login.id, remaining))
        case .unknown: break
        }
    }
    if let first = firstLeast(expired) { return .expired(id: first.id) }
    if let soonest = firstLeast(expiring) { return .expiring(id: soonest.id, remaining: soonest.key) }
    if let soonest = firstLeast(ok) { return .ok(id: soonest.id, remaining: soonest.key) }
    return .noTimer
}

/// The candidate with the least key, the earliest one on a tie.
private func firstLeast<Key: Comparable>(_ candidates: [(id: UUID, key: Key)]) -> (id: UUID, key: Key)? {
    candidates.reduce(nil) { least, candidate in
        guard let least, least.key <= candidate.key else { return candidate }
        return least
    }
}
