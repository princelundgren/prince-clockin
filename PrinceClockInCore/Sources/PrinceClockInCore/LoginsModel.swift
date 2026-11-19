import Foundation

/// The stored state plus what the app knows only while running, changed by one event at a time.
/// It does no I/O and reads no clock: every time comes in with its event.
public struct LoginsModel: Equatable, Sendable {
    public var state: AppState
    /// AWS logins whose cache rewrite could be a login or a renewal, with the rewrite's time. The
    /// row asks "Logged in at <time>?".
    public var possibleLogins: [UUID: Date] = [:]

    public init(state: AppState) {
        self.state = state
    }

    /// A login that succeeded sets its login time. A failure leaves the timer as it was.
    public mutating func apply(_ event: QueueEvent) {
        guard case .succeeded(let id, let time) = event else { return }
        changeLoginTime(of: id) { $0.loginTime = time.wholeSeconds }
    }

    /// Records what the AWS cache file showed for login `id`. A logout counts from `now`.
    public mutating func apply(_ observation: AWSCacheObservation, login id: UUID, now: Date) {
        switch observation {
        case .newLogin(let time):
            changeLoginTime(of: id) { $0.loginTime = time.wholeSeconds }
        case .possibleLogin(let time):
            guard index(of: id) != nil else { return }
            possibleLogins[id] = time.wholeSeconds
        case .loggedOut:
            invalidate(id, at: now, reason: .loggedOut)
        case .noChange, .renewed:
            break
        }
    }

    /// The user's yes to "Logged in at <time>?": the login time becomes the rewrite's time.
    public mutating func confirmPossibleLogin(id: UUID) {
        guard let time = possibleLogins[id] else { return }
        setLoginTime(id: id, at: time)
    }

    /// Records a Databricks check of login `id` made at `now`, whatever it found, and a valid or
    /// invalid one as its last answer. Invalid invalidates the login. Valid after being found
    /// invalid is a login at `now`, the best time the app knows. Couldn't check changes nothing
    /// else.
    public mutating func apply(_ result: DatabricksCheckResult, login id: UUID, now: Date) {
        guard let index = index(of: id) else { return }
        let record = DatabricksCheckRecord(at: now, result: result)
        switch result {
        case .invalid:
            invalidate(id, at: now, reason: .foundInvalid)
        case .valid where isInvalidated(state.logins[index]):
            changeLoginTime(of: id) { $0.loginTime = now.wholeSeconds }
        case .valid, .couldntCheck:
            break
        }
        state.logins[index].lastDatabricksCheck = record
        if result != .couldntCheck { state.logins[index].lastDatabricksAnswer = record }
    }

    /// The logins due a warning at `now`, in stored order, each marked as warned for its current
    /// expiry so the next call, or a relaunch, doesn't return it again.
    public mutating func takeWarnings(now: Date) -> [UUID] {
        let due = warningsDue(state.logins, now: now, leadTime: state.settings.warningLeadTime)
        for id in due {
            guard let index = index(of: id) else { continue }
            state.logins[index].warnedForExpiry = expiry(of: state.logins[index])
        }
        return due
    }

    /// The Databricks logins among `ids`, in the order of `ids`.
    public func databricksLogins(among ids: [UUID]) -> [Login] {
        trackedLogins(ids).filter(isDatabricks)
    }

    /// Every tracked Databricks login, for "Check now".
    public func checkNowTargets() -> [Login] {
        state.logins.filter(isDatabricks)
    }

    /// The logins due at `now`, in stored order, for Log In to N Due: expiring or expired, never
    /// still valid and never with an unknown timer.
    public func dueLogins(now: Date) -> [Login] {
        state.logins.filter { isDue($0, now: now, leadTime: state.settings.warningLeadTime) }
    }

    /// The order of the panel's tiles at `now`: due logins by time left, so the expired come first,
    /// the first to expire first; then the others with time left, by time left; then the still
    /// valid; then those with no timer. Ties keep the stored order, since `sorted` is stable.
    public func panelOrder(now: Date) -> [Login] {
        let leadTime = state.settings.warningLeadTime
        return state.logins
            .map { (key: panelSortKey($0, now: now, leadTime: leadTime), login: $0) }
            .sorted { ($0.key.group, $0.key.timeLeft) < ($1.key.group, $1.key.timeLeft) }
            .map(\.login)
    }

    /// The tracked logins in the order `ids` gives, which the panel took when it opened, so its
    /// tiles hold still while it is open. A login removed since is left out; one added since
    /// follows, in stored order.
    public func logins(inOrder ids: [UUID]) -> [Login] {
        let ordered = trackedLogins(ids)
        let placed = Set(ids)
        return ordered + state.logins.filter { !placed.contains($0.id) }
    }

    /// The preset's logins in its order, skipping any no longer tracked.
    public func logins(in preset: Preset) -> [Login] {
        trackedLogins(preset.loginIDs)
    }

    /// Stops tracking login `id` and takes it out of every preset. A preset left with no logins
    /// stays.
    public mutating func removeLogin(id: UUID) {
        state.logins.removeAll { $0.id == id }
        for index in state.presets.indices {
            state.presets[index].loginIDs.removeAll { $0 == id }
        }
        possibleLogins[id] = nil
    }

    /// The user stating when login `id` logged in: sets its login time, rounded down to whole
    /// seconds, and clears any invalidation, since the user is saying the login is valid.
    public mutating func setLoginTime(id: UUID, at time: Date) {
        changeLoginTime(of: id) { login in
            login.loginTime = time.wholeSeconds
            login.invalidatedAt = nil
            login.invalidationReason = nil
        }
    }

    /// Set Timer with Expires In: the login expires `expiresIn` after `now`, and its session length
    /// becomes `sessionLength`, so the time left is never stored as the length.
    /// - Throws: `TimerError.wouldAlreadyBeExpired` when `expiresIn` is zero or less, and
    ///   `.longerThanSessionLength` when it exceeds `sessionLength`, leaving the model unchanged.
    public mutating func setTimer(
        id: UUID, expiresIn: TimeInterval, sessionLength: TimeInterval, now: Date
    ) throws(TimerError) {
        let expiresIn = expiresIn.rounded(.down)
        let length = sessionLength.rounded(.down)
        guard expiresIn > 0 else { throw TimerError.wouldAlreadyBeExpired }
        guard expiresIn <= length else { throw TimerError.longerThanSessionLength }
        setSessionLengthAndLoginTime(id: id, length: length, loginTime: now.addingTimeInterval(expiresIn - length))
    }

    /// Set Timer with Logged In At: the login logged in at `loggedInAt`, with session length
    /// `sessionLength`.
    /// - Throws: `TimerError.inFuture` when `loggedInAt` is after `now`, and
    ///   `.wouldAlreadyBeExpired` when the login would have expired by `now`, leaving the model
    ///   unchanged.
    public mutating func setTimer(
        id: UUID, loggedInAt: Date, sessionLength: TimeInterval, now: Date
    ) throws(TimerError) {
        let loggedInAt = loggedInAt.wholeSeconds
        let length = sessionLength.rounded(.down)
        guard loggedInAt <= now else { throw TimerError.inFuture }
        guard loggedInAt.addingTimeInterval(length) > now else { throw TimerError.wouldAlreadyBeExpired }
        setSessionLengthAndLoginTime(id: id, length: length, loginTime: loggedInAt)
    }

    /// The user's Mark as Logged In Now.
    public mutating func markLoggedInNow(id: UUID, now: Date) {
        setLoginTime(id: id, at: now)
    }

    private mutating func setSessionLengthAndLoginTime(id: UUID, length: TimeInterval, loginTime: Date) {
        guard let index = index(of: id) else { return }
        state.logins[index].sessionLength = length
        setLoginTime(id: id, at: loginTime)
    }

    /// Every write of a login time goes through here. A new login time answers the "Logged in
    /// at?" question, whatever time it sets.
    private mutating func changeLoginTime(of id: UUID, _ change: (inout Login) -> Void) {
        guard let index = index(of: id) else { return }
        change(&state.logins[index])
        possibleLogins[id] = nil
    }

    private mutating func invalidate(_ id: UUID, at now: Date, reason: InvalidationReason) {
        guard let index = index(of: id) else { return }
        state.logins[index].invalidatedAt = now.wholeSeconds
        state.logins[index].invalidationReason = reason
    }

    private func index(of id: UUID) -> Int? {
        state.logins.firstIndex { $0.id == id }
    }

    private func trackedLogins(_ ids: [UUID]) -> [Login] {
        ids.compactMap { id in index(of: id).map { state.logins[$0] } }
    }
}

/// The panel's group for the login, 0 first, and its time left within the group: negative for an
/// expired login, counted from when it expired.
private func panelSortKey(_ login: Login, now: Date, leadTime: TimeInterval) -> (group: Int, timeLeft: TimeInterval) {
    if isStillValid(login, now: now) { return (2, 0) }
    switch timerState(for: login, now: now, leadTime: leadTime) {
    case .expired: return (0, (expiredAt(login) ?? now).timeIntervalSince(now))
    case .expiring(let remaining): return (0, remaining)
    case .ok(let remaining): return (1, remaining)
    case .unknown: return (3, 0)
    }
}

private func isDatabricks(_ login: Login) -> Bool {
    if case .databricksProfile = login.kind { return true }
    return false
}
