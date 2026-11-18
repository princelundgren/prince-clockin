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

/// The identifiers of the notification buttons the app registers.
public enum NotificationActionID {
    /// "Log in", on a warning: starts the logins it names.
    public static let logIn = "logIn"
    /// "Done", on a custom login waiting for the user.
    public static let done = "customDone"
}

/// What the user asked for by pressing a notification's button.
public enum NotificationAction: Equatable, Sendable {
    case logIn([UUID])
    case customDone(UUID)
}

/// The action for a notification response. Only the "Log in" and "Done" buttons give one: opening
/// or dismissing the notification gives `nil`, so nothing logs in unasked. Strings that aren't
/// UUIDs are dropped, and a response left with no login gives `nil`.
public func notificationAction(actionIdentifier: String, loginIDs: [String]) -> NotificationAction? {
    let ids = loginIDs.compactMap(UUID.init(uuidString:))
    switch actionIdentifier {
    case NotificationActionID.logIn: return ids.isEmpty ? nil : .logIn(ids)
    case NotificationActionID.done: return ids.first.map(NotificationAction.customDone)
    default: return nil
    }
}
