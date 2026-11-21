import Foundation

/// Login times and session lengths are whole seconds, so one second past a minute's boundary is
/// the first whole second whose time left, rounded down, shows the next minute.
private let pastTheBoundary: TimeInterval = 1

/// Which times the user can see now, which decides how often the app must recompute.
public enum ShownTimes: Sendable {
    /// None: the panel and Settings are closed and VoiceOver is off.
    case none
    /// Only the menu bar item's label, which VoiceOver reads with one login's time left.
    case menuBarLabel
    /// The panel or Settings: every tile's time, and Set Timer's caption, timed against the clock.
    case all
}

/// When the app must next recompute, or `nil` when nothing changes until something happens: now
/// while an expiry notification is due and not sent, or the start of `workingHours`, read in
/// `calendar`, when it is due outside them; else the soonest notification time or expiry after
/// `now`. With `.menuBarLabel`, also the next minute of the time left the label speaks. With
/// `.all`, also the next minute of every tile's time left or time since expiry, and the next
/// minute of the clock in `calendar`, which moves Set Timer's caption and a shown "tomorrow" on.
public func nextTickDeadline(
    _ logins: [Login], now: Date, leadTime: TimeInterval, workingHours: WorkingHours, shown: ShownTimes,
    calendar: Calendar
) -> Date? {
    var deadlines: [Date] = []
    if !expiryNotificationsDue(logins, now: now, leadTime: leadTime).isEmpty,
       let notifying = workingHours.nextNotifyingTime(onOrAfter: now, calendar: calendar) {
        if notifying <= now { return now }
        deadlines.append(notifying)
    }
    for login in logins {
        guard !isInvalidated(login), let expiry = expiry(of: login) else { continue }
        deadlines += [expiry.addingTimeInterval(-leadTime), expiry]
    }
    switch shown {
    case .none:
        break
    case .menuBarLabel:
        switch menuBarStatus(logins, now: now, leadTime: leadTime, batch: nil, hasFailure: false) {
        case .ok(let id, let remaining), .expiring(let id, let remaining):
            if let expiry = logins.first(where: { $0.id == id }).flatMap(expiry(of:)) {
                deadlines.append(nextMinute(ofTimeLeft: remaining, until: expiry))
            }
        case .loggingIn, .failure, .expired, .loggedIn, .noTimer:
            break
        }
    case .all:
        deadlines += logins.compactMap { nextMinuteOfShownTime($0, now: now, leadTime: leadTime) }
        if let minute = calendar.nextDate(after: now, matching: DateComponents(second: 0), matchingPolicy: .nextTime) {
            deadlines.append(minute)
        }
    }
    return deadlines.filter { $0 > now }.min()
}

/// The next minute of the time left or time since expiry a login's tile shows, or `nil` for a tile
/// that shows neither: no timer, logged out, or still valid.
private func nextMinuteOfShownTime(_ login: Login, now: Date, leadTime: TimeInterval) -> Date? {
    switch timerState(for: login, now: now, leadTime: leadTime) {
    case .ok(let remaining), .expiring(let remaining):
        return expiry(of: login).map { nextMinute(ofTimeLeft: remaining, until: $0) }
    case .expired:
        guard !isLoggedOut(login), !isStillValid(login, now: now), let expiredAt = expiredAt(login) else { return nil }
        return expiredAt.addingTimeInterval(60 * ((now.timeIntervalSince(expiredAt) / 60).rounded(.down) + 1))
    case .unknown:
        return nil
    }
}

private func nextMinute(ofTimeLeft remaining: TimeInterval, until expiry: Date) -> Date {
    expiry.addingTimeInterval(-60 * (remaining / 60).rounded(.down) + pastTheBoundary)
}
