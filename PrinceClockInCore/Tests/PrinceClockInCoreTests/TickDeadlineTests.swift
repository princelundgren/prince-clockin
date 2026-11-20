import Foundation
import Testing
import PrinceClockInCore

private let eightHours: TimeInterval = 8 * 3600
private let lead: TimeInterval = 30 * 60
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// An AWS login whose session started at `loginTime`. Starting it 20 seconds past a minute puts
/// its own minute boundaries apart from the clock's, so a test can tell them apart.
private func timed(_ loginTime: String, name: String = "dev") -> Login {
    Login(displayName: name, kind: .awsSSOSession(name: name), sessionLength: eightHours, loginTime: at(loginTime))
}

private func notified(_ login: Login) -> Login {
    var login = login
    login.notifiedForExpiry = expiry(of: login)
    return login
}

private func deadline(_ logins: [Login], now: String, shown: ShownTimes = .none) -> Date? {
    nextTickDeadline(logins, now: at(now), leadTime: lead, shown: shown, calendar: utc)
}

@Test func noTimerNeedsNoTick() {
    let untimed = Login(displayName: "dev", kind: .awsSSOSession(name: "dev"))

    #expect(deadline([], now: "2026-11-17T12:00:00Z") == nil)
    #expect(deadline([untimed], now: "2026-11-17T12:00:00Z") == nil)
    #expect(deadline([untimed], now: "2026-11-17T12:00:00Z", shown: .menuBarLabel) == nil)
}

@Test func hiddenTimesWakeOnlyAtNotificationTimeAndExpiry() {
    let login = timed("2026-11-17T09:00:00Z")

    #expect(deadline([login], now: "2026-11-17T12:00:00Z") == at("2026-11-17T16:30:00Z"))
    #expect(deadline([notified(login)], now: "2026-11-17T16:30:00Z") == at("2026-11-17T17:00:00Z"))
    #expect(deadline([notified(login)], now: "2026-11-17T17:00:00Z") == nil)
}

@Test func soonestLoginWins() {
    let later = timed("2026-11-17T10:00:00Z")
    let sooner = timed("2026-11-17T09:00:00Z")

    #expect(deadline([later, sooner], now: "2026-11-17T12:00:00Z") == at("2026-11-17T16:30:00Z"))
}

@Test func unsentNotificationTicksAtOnce() {
    let now = "2026-11-17T16:40:00Z"
    let login = timed("2026-11-17T09:00:00Z")

    #expect(deadline([login], now: now) == at(now))
    #expect(deadline([notified(login)], now: now) == at("2026-11-17T17:00:00Z"))
}

@Test func shownTimeLeftTicksJustPastEachMinute() {
    let login = timed("2026-11-17T09:00:20Z")

    // 5h 0m 10s left shows "5h" until 5h left at 12:00:20, then "4h 59m" a second later.
    #expect(deadline([login], now: "2026-11-17T12:00:10Z", shown: .all) == at("2026-11-17T12:00:21Z"))
}

@Test func shownTimeSinceExpiryTicksAtEachMinute() {
    let login = notified(timed("2026-11-17T09:00:20Z"))

    #expect(deadline([login], now: "2026-11-17T17:01:10Z", shown: .all) == at("2026-11-17T17:01:20Z"))
}

@Test func loggedOutLoginShowsNoTimeToTick() {
    var login = notified(timed("2026-11-17T09:00:20Z"))
    login.invalidatedAt = at("2026-11-17T11:00:20Z")
    login.invalidationReason = .loggedOut

    #expect(deadline([login], now: "2026-11-17T11:01:10Z", shown: .all) == at("2026-11-17T11:02:00Z"))

    login.invalidationReason = .foundInvalid
    #expect(deadline([login], now: "2026-11-17T11:01:10Z", shown: .all) == at("2026-11-17T11:01:20Z"))
}

@Test func stillValidLoginShowsNoTimeToTick() {
    var login = Login(
        displayName: "analytics-dev", kind: .databricksProfile(name: "analytics-dev", accountLevel: false),
        sessionLength: eightHours, loginTime: at("2026-11-17T09:00:20Z"))
    login = notified(login)
    login.lastDatabricksAnswer = DatabricksCheckRecord(at: at("2026-11-17T17:00:30Z"), result: .valid)

    #expect(deadline([login], now: "2026-11-17T17:01:10Z", shown: .all) == at("2026-11-17T17:02:00Z"))
}

@Test func shownPanelTicksAtEachMinuteOfTheClock() {
    let untimed = Login(displayName: "dev", kind: .awsSSOSession(name: "dev"))

    #expect(deadline([untimed], now: "2026-11-17T12:00:30Z", shown: .all) == at("2026-11-17T12:01:00Z"))
    #expect(deadline([untimed], now: "2026-11-17T23:59:00Z", shown: .all) == at("2026-11-18T00:00:00Z"))
}

@Test func menuBarLabelTicksOnlyForTheLoginItNames() {
    let named = timed("2026-11-17T09:00:40Z", name: "named")
    let other = timed("2026-11-17T09:10:20Z", name: "other")

    // At 12:00:10 the named login has 5h 0m 30s left, the other 5h 10m 10s.
    #expect(deadline([named, other], now: "2026-11-17T12:00:10Z", shown: .menuBarLabel) == at("2026-11-17T12:00:41Z"))
    #expect(deadline([named, other], now: "2026-11-17T12:00:10Z", shown: .all) == at("2026-11-17T12:00:21Z"))
}
