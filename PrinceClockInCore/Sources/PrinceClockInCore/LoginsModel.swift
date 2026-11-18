import Foundation

/// The stored state plus what the app knows only while running, changed by one event at a time.
/// It does no I/O and reads no clock: every time comes in with its event.
public struct LoginsModel: Equatable, Sendable {
    public var state: AppState
    /// Databricks logins the CLI reports valid while their timer says expired. The row shows both
    /// facts and offers to correct the session length.
    public var validWhileExpired: Set<UUID> = []
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
            invalidate(id, at: now)
        case .noChange, .renewed:
            break
        }
    }

    /// The user's yes to "Logged in at <time>?": the login time becomes the rewrite's time.
    public mutating func confirmPossibleLogin(id: UUID) {
        guard let time = possibleLogins[id] else { return }
        changeLoginTime(of: id) { $0.loginTime = time }
    }

    /// Records a Databricks check of login `id` made at `now`. Valid after being found invalid is a
    /// login at `now`, the best time the app knows. Valid while the timer says expired is flagged
    /// in `validWhileExpired`.
    public mutating func apply(_ validity: DatabricksValidity, login id: UUID, now: Date) {
        guard let index = index(of: id) else { return }
        let login = state.logins[index]
        switch validity {
        case .invalid:
            invalidate(id, at: now)
        case .valid where isInvalidated(login):
            changeLoginTime(of: id) { $0.loginTime = now.wholeSeconds }
        case .valid:
            let timer = timerState(for: login, now: now, leadTime: state.settings.warningLeadTime)
            if timer == .expired { validWhileExpired.insert(id) }
        }
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

    /// The logins that are expiring or expired at `now`, for "Log in to expiring".
    public func expiringOrExpired(now: Date) -> [Login] {
        state.logins.filter { login in
            switch timerState(for: login, now: now, leadTime: state.settings.warningLeadTime) {
            case .expiring, .expired: true
            case .ok, .unknown: false
            }
        }
    }

    /// The preset's logins in its order, skipping any no longer tracked.
    public func logins(in preset: Preset) -> [Login] {
        trackedLogins(preset.loginIDs)
    }

    /// The user's "expires at": see the free `setExpiry`, which this applies to login `id`.
    /// - Throws: `TimerError.expiryInPast`, leaving the model unchanged.
    public mutating func setExpiry(id: UUID, expiresAt: Date, now: Date) throws {
        try changeLoginTime(of: id) { try PrinceClockInCore.setExpiry(&$0, expiresAt: expiresAt, now: now) }
    }

    /// The user's "logged in now".
    public mutating func markLoggedInNow(id: UUID, now: Date) {
        changeLoginTime(of: id) { $0.loginTime = now.wholeSeconds }
    }

    /// Every write of a login time goes through here. A new login time answers the "Logged in
    /// at?" question and ends any "valid while expired" mismatch, whatever time it sets.
    private mutating func changeLoginTime(of id: UUID, _ change: (inout Login) throws -> Void) rethrows {
        guard let index = index(of: id) else { return }
        try change(&state.logins[index])
        possibleLogins[id] = nil
        validWhileExpired.remove(id)
    }

    private mutating func invalidate(_ id: UUID, at now: Date) {
        guard let index = index(of: id) else { return }
        state.logins[index].invalidatedAt = now.wholeSeconds
        validWhileExpired.remove(id)
    }

    private func index(of id: UUID) -> Int? {
        state.logins.firstIndex { $0.id == id }
    }

    private func trackedLogins(_ ids: [UUID]) -> [Login] {
        ids.compactMap { id in index(of: id).map { state.logins[$0] } }
    }
}

private func isDatabricks(_ login: Login) -> Bool {
    if case .databricksProfile = login.kind { return true }
    return false
}
