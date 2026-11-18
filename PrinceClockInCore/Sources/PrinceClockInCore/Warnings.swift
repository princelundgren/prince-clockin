import Foundation

/// One grouped notification for the logins that entered their warning time.
public struct WarningContent: Equatable, Sendable {
    public let title: String
    public let body: String
    /// The logins the notification's "Log in" action starts, in the order given.
    public let ids: [UUID]

    public init(title: String, body: String, ids: [UUID]) {
        self.title = title
        self.body = body
        self.ids = ids
    }
}

/// The logins, in the order given, that have reached their warning time and haven't been warned
/// for their current expiry. That includes ones that expired while the Mac slept or the app wasn't
/// running. An unknown timer, or a login invalidated since its last login time, never warns.
public func warningsDue(_ logins: [Login], now: Date, leadTime: TimeInterval) -> [UUID] {
    logins.filter { login in
        guard let expiry = expiry(of: login), !isInvalidated(login) else { return false }
        return now >= expiry.addingTimeInterval(-leadTime) && login.warnedForExpiry != expiry
    }
    .map(\.id)
}

/// One login is named in the title. Several are counted in the title and listed in the body, one
/// per line. Each is described by its state at `now`: "expires in 25m" or "expired".
public func warningContent(_ logins: [Login], now: Date) -> WarningContent {
    let ids = logins.map(\.id)
    if logins.count == 1, let login = logins.first {
        return WarningContent(
            title: "\(login.displayName) \(describe(login, now: now))", body: "Log in to renew it.", ids: ids)
    }
    let lines = logins.map { "\($0.displayName): \(describe($0, now: now))" }
    return WarningContent(
        title: "\(logins.count) logins need logging in", body: lines.joined(separator: "\n"), ids: ids)
}

private func describe(_ login: Login, now: Date) -> String {
    switch timerState(for: login, now: now, leadTime: 0) {
    case .ok(let remaining), .expiring(let remaining): "expires in \(remainingText(remaining))"
    case .expired: "expired"
    case .unknown: "has no known expiry"
    }
}
