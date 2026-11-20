import Foundation

/// One grouped notification for the logins that entered their notification time.
public struct ExpiryNotificationContent: Equatable, Sendable {
    public let title: String
    public let body: String
    /// The logins the notification's "Log In" action starts, in the order given.
    public let ids: [UUID]

    public init(title: String, body: String, ids: [UUID]) {
        self.title = title
        self.body = body
        self.ids = ids
    }
}

/// The logins, in the order given, that have reached their notification time and haven't been
/// notified for their current expiry. That includes ones that expired while the Mac slept or the app
/// wasn't running. An unknown timer, a login invalidated since its last login time, or a Still
/// valid login is never notified.
public func expiryNotificationsDue(_ logins: [Login], now: Date, leadTime: TimeInterval) -> [UUID] {
    logins.filter { login in
        guard let expiry = expiry(of: login), !isInvalidated(login), !isStillValid(login, now: now)
        else { return false }
        return now >= expiry.addingTimeInterval(-leadTime) && login.notifiedForExpiry != expiry
    }
    .map(\.id)
}

/// One login is named in the title. Several are counted in the title and listed in the body, one
/// per line. Each is described by its state at `now`: "expires in 25m", with the time left in
/// `locale`'s narrow form, or "expired".
public func expiryNotificationContent(_ logins: [Login], now: Date, locale: Locale) -> ExpiryNotificationContent {
    let ids = logins.map(\.id)
    if logins.count == 1, let login = logins.first {
        return ExpiryNotificationContent(
            title: "\(login.displayName) \(describe(login, now: now, locale: locale))", body: "Log in to renew it.",
            ids: ids)
    }
    let lines = logins.map { "\($0.displayName): \(describe($0, now: now, locale: locale))" }
    return ExpiryNotificationContent(
        title: "\(logins.count) logins need logging in", body: lines.joined(separator: "\n"), ids: ids)
}

private func describe(_ login: Login, now: Date, locale: Locale) -> String {
    switch timerState(for: login, now: now, leadTime: 0) {
    case .ok(let remaining), .expiring(let remaining): "expires in \(timeLeftText(remaining, locale: locale))"
    case .expired: "expired"
    case .unknown: "has no timer"
    }
}

/// A notification's title and body.
public struct NotificationText: Equatable, Sendable {
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

/// The notification for custom login `login` waiting for the user's Done. Only a login with a
/// command mentions Terminal, since one without opens nothing.
public func customDoneContent(_ login: Login) -> NotificationText {
    if case .custom(command: nil) = login.kind {
        NotificationText(title: "\(login.displayName) is waiting for you", body: "Log in your own way, then click Done.")
    } else {
        NotificationText(
            title: "\(login.displayName) is waiting in Terminal", body: "Finish the login there, then click Done.")
    }
}

/// The identifiers of the notification buttons the app registers.
public enum NotificationActionID {
    /// "Log In", on an expiry notification: starts the logins it names.
    public static let logIn = "logIn"
    /// "Done", on a custom login waiting for the user.
    public static let done = "customDone"
}

/// What the user asked for by pressing a notification's button.
public enum NotificationAction: Equatable, Sendable {
    case logIn([UUID])
    case customDone(UUID)
}

/// The action for a notification response. Only the "Log In" and "Done" buttons give one: opening
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
