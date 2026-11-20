import Foundation

public enum TimerState: Equatable, Sendable {
    case ok(remaining: TimeInterval)
    /// Within the notification lead time, and not yet expired.
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
    /// A session length longer than `maximumSessionLength`, or not a finite number.
    case sessionLengthTooLong
    /// A session length of zero or less, once rounded down to whole seconds.
    case sessionLengthNotPositive

    public var message: String {
        switch self {
        case .wouldAlreadyBeExpired: "That login would already have expired"
        case .inFuture: "That time is in the future"
        case .longerThanSessionLength: "That's longer than the session length"
        case .sessionLengthTooLong: "A session length can be at most a year"
        case .sessionLengthNotPositive: "A session length must be more than zero"
        }
    }
}

/// The longest session length a login can have: a year.
public let maximumSessionLength: TimeInterval = 365 * 24 * 3600

/// `length` rounded down to whole seconds, as a login stores it.
/// - Throws: `.sessionLengthTooLong` when it isn't finite or is longer than `maximumSessionLength`;
///   `.sessionLengthNotPositive` when it is zero or less.
public func checkedSessionLength(_ length: TimeInterval) throws(TimerError) -> TimeInterval {
    let length = length.rounded(.down)
    guard length.isFinite, length <= maximumSessionLength else { throw .sessionLengthTooLong }
    guard length > 0 else { throw .sessionLengthNotPositive }
    return length
}

/// What Set Timer was told, either way, with the session length it sets.
public enum TimerEntry: Equatable, Sendable {
    /// The login expires this long from now.
    case expiresIn(TimeInterval, sessionLength: TimeInterval)
    /// The login logged in at this time.
    case loggedInAt(Date, sessionLength: TimeInterval)
}

/// A login time and session length that Set Timer accepted, in whole seconds.
public struct TimerSetting: Equatable, Sendable {
    public let loginTime: Date
    public let sessionLength: TimeInterval

    public init(loginTime: Date, sessionLength: TimeInterval) {
        self.loginTime = loginTime
        self.sessionLength = sessionLength
    }

    public var expiry: Date { loginTime.addingTimeInterval(sessionLength) }
}

/// The login time and session length `entry` sets at `now`. Expires In becomes a login time through
/// the session length, so the time left is never stored as the length.
/// - Throws: `TimerError.wouldAlreadyBeExpired` for an Expires In of zero or less, or a Logged In
///   At a session length or more ago; `.longerThanSessionLength` for an Expires In longer than the
///   session length; `.inFuture` for a Logged In At after `now`; `.sessionLengthTooLong` for a
///   session length that isn't finite or is longer than `maximumSessionLength`;
///   `.sessionLengthNotPositive` for one of zero or less, or under a second.
public func timerSetting(for entry: TimerEntry, now: Date) throws(TimerError) -> TimerSetting {
    switch entry {
    case .expiresIn(let expiresIn, let sessionLength):
        let expiresIn = expiresIn.rounded(.down)
        let length = try checkedSessionLength(sessionLength)
        guard expiresIn > 0 else { throw .wouldAlreadyBeExpired }
        guard expiresIn <= length else { throw .longerThanSessionLength }
        return TimerSetting(loginTime: now.addingTimeInterval(expiresIn - length).wholeSeconds, sessionLength: length)
    case .loggedInAt(let loggedInAt, let sessionLength):
        let loggedInAt = loggedInAt.wholeSeconds
        let length = try checkedSessionLength(sessionLength)
        guard loggedInAt <= now else { throw .inFuture }
        guard loggedInAt.addingTimeInterval(length) > now else { throw .wouldAlreadyBeExpired }
        return TimerSetting(loginTime: loggedInAt, sessionLength: length)
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

/// Whether a login with no session length has been logged in to, and not invalidated since: its
/// timer is unknown.
func isLoggedInWithNoLength(_ login: Login) -> Bool {
    login.loginTime != nil && login.sessionLength == nil && !isInvalidated(login)
}

/// Whether an AWS SSO session, gcloud account or custom login is logged in with no session length,
/// which shows as logged in. A Databricks login in that state asks for its session length instead.
func isLoggedInWithNoExpiry(_ login: Login) -> Bool {
    if case .databricksProfile = login.kind { return false }
    return isLoggedInWithNoLength(login)
}

/// Whether the login is invalidated because its AWS session or gcloud account was logged out, for
/// "Logged out". With no stored reason, an AWS login counts as logged out, since a logout was its
/// only cause before the reason was stored.
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

/// Whether a Databricks workspace login's or gcloud login's timer has run out while its last check
/// that answered, made at or after that expiry, found it valid. A new login time, a longer session
/// or a later invalid answer ends it; a check that couldn't check doesn't.
public func isStillValid(_ login: Login, now: Date) -> Bool {
    switch login.kind {
    case .databricksProfile(_, accountLevel: false), .gcloudAccount: break
    case .databricksProfile, .awsSSOSession, .custom: return false
    }
    guard !isInvalidated(login), let expiry = expiry(of: login), expiry <= now,
          let answer = login.lastDatabricksAnswer
    else { return false }
    return answer.result == .valid && answer.at >= expiry
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
/// one login carries its id, so the VoiceOver label's time and the login it names always agree.
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
    /// No login has a timer, and this one, the first stored, is logged in with no expiry.
    case loggedIn(id: UUID)
    /// No login has time left, is expiring or has expired, leaving out the still valid, and none is
    /// logged in with no expiry.
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
    if let loggedIn = logins.first(where: isLoggedInWithNoExpiry) { return .loggedIn(id: loggedIn.id) }
    return .noTimer
}

/// The candidate with the least key, the earliest one on a tie.
private func firstLeast<Key: Comparable>(_ candidates: [(id: UUID, key: Key)]) -> (id: UUID, key: Key)? {
    candidates.reduce(nil) { least, candidate in
        guard let least, least.key <= candidate.key else { return candidate }
        return least
    }
}
