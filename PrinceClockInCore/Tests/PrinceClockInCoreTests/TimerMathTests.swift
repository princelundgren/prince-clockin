import Foundation
import Testing
import PrinceClockInCore

private let eightHours: TimeInterval = 8 * 3600
private let lead: TimeInterval = 30 * 60

@Test func stateIsUnknownWithoutLoginTimeOrLength() {
    let now = at("2026-11-17T12:00:00Z")
    let kind = LoginKind.awsSSOSession(name: "dev")
    let noTime = Login(displayName: "dev", kind: kind, sessionLength: eightHours)
    let noLength = Login(displayName: "dev", kind: kind, loginTime: at("2026-11-17T09:00:00Z"))

    #expect(timerState(for: noTime, now: now, leadTime: lead) == .unknown)
    #expect(timerState(for: noLength, now: now, leadTime: lead) == .unknown)
}

@Test func stateIsOkOutsideLeadTime() {
    let login = Login(displayName: "dev", kind: .awsSSOSession(name: "dev"),
                      sessionLength: eightHours, loginTime: at("2026-11-17T09:00:00Z"))

    #expect(timerState(for: login, now: at("2026-11-17T12:00:00Z"), leadTime: lead) == .ok(remaining: 5 * 3600))
}

@Test func stateIsExpiringInsideLeadTime() {
    let login = Login(displayName: "dev", kind: .awsSSOSession(name: "dev"),
                      sessionLength: eightHours, loginTime: at("2026-11-17T09:00:00Z"))

    #expect(timerState(for: login, now: at("2026-11-17T16:31:00Z"), leadTime: lead) == .expiring(remaining: 29 * 60))
}

@Test func stateIsExpiredAtExpiry() {
    let login = Login(displayName: "dev", kind: .awsSSOSession(name: "dev"),
                      sessionLength: eightHours, loginTime: at("2026-11-17T09:00:00Z"))

    #expect(timerState(for: login, now: at("2026-11-17T17:00:00Z"), leadTime: lead) == .expired)
    #expect(timerState(for: login, now: at("2026-11-17T18:00:00Z"), leadTime: lead) == .expired)
}

@Test func invalidatedLoginIsExpiredUntilNewerLogin() {
    let now = at("2026-11-17T12:00:00Z")
    let invalidatedAt = at("2026-11-17T11:00:00Z")
    var login = Login(displayName: "dev", kind: .awsSSOSession(name: "dev"), sessionLength: eightHours,
                      loginTime: at("2026-11-17T09:00:00Z"), invalidatedAt: invalidatedAt)
    #expect(timerState(for: login, now: now, leadTime: lead) == .expired)

    login.loginTime = invalidatedAt
    #expect(timerState(for: login, now: now, leadTime: lead) == .expired)

    login.loginTime = at("2026-11-17T11:30:00Z")
    #expect(timerState(for: login, now: now, leadTime: lead) == .ok(remaining: 7.5 * 3600))
}

@Test func invalidatedLoginWithoutLoginTimeIsExpired() {
    let login = Login(displayName: "dev", kind: .awsSSOSession(name: "dev"), sessionLength: eightHours,
                      invalidatedAt: at("2026-11-17T11:00:00Z"))

    #expect(timerState(for: login, now: at("2026-11-17T12:00:00Z"), leadTime: lead) == .expired)
}

@Test func stateUsesAbsoluteTimes() {
    let login = Login(displayName: "dev", kind: .awsSSOSession(name: "dev"),
                      sessionLength: eightHours, loginTime: at("2026-11-17T09:00:00Z"))
    let now = at("2026-11-17T12:00:00Z")

    #expect(timerState(for: login, now: now, leadTime: lead) == .ok(remaining: 5 * 3600))
    #expect(timerState(for: login, now: now.addingTimeInterval(3 * 3600), leadTime: lead) == .ok(remaining: 2 * 3600))
    #expect(timerState(for: login, now: now.addingTimeInterval(5 * 3600), leadTime: lead) == .expired)
}

private let now = at("2026-11-17T12:00:00Z")

private func status(_ logins: [Login], batch: BatchProgress? = nil, hasFailure: Bool = false) -> MenuBarStatus {
    menuBarStatus(logins, now: now, leadTime: lead, batch: batch, hasFailure: hasFailure)
}

private func stillValid(_ name: String) -> Login {
    Login(
        displayName: name, kind: .databricksProfile(name: name, accountLevel: false), sessionLength: 3600,
        loginTime: now.addingTimeInterval(-7200), lastDatabricksAnswer: DatabricksCheckRecord(at: now, result: .valid))
}

private let noTimer = Login(displayName: "vpn", kind: .custom(command: nil))

@Test func menuBarShowsTheBatchAboveEverything() {
    let batch = BatchProgress(position: 1, total: 2)

    #expect(status([login(remaining: -60, now: now)], batch: batch, hasFailure: true) == .loggingIn(batch))
}

@Test func menuBarShowsAFailureAboveAnExpiredLogin() {
    #expect(status([login(remaining: -60, now: now)], hasFailure: true) == .failure)
}

@Test func menuBarExpiredIsAboutTheLoginThatExpiredFirst() {
    let expiring = login(remaining: 10 * 60, now: now, name: "dev")
    let recently = login(remaining: -60, now: now, name: "prod")
    let longAgo = login(remaining: -3600, now: now, name: "qa")

    #expect(status([expiring, recently, longAgo]) == .expired(id: longAgo.id))
}

@Test func menuBarCountsAnInvalidatedLoginFromWhenItWasInvalidated() {
    let expired = login(remaining: -3600, now: now, name: "dev")
    var loggedOut = login(remaining: 4 * 3600, now: now, name: "prod")
    loggedOut.invalidatedAt = now.addingTimeInterval(-2 * 3600)

    #expect(status([expired, loggedOut]) == .expired(id: loggedOut.id))
}

@Test func menuBarExpiredTieGoesToTheFirstStored() {
    let first = login(remaining: -60, now: now, name: "dev")
    let second = login(remaining: -60, now: now, name: "prod")

    #expect(status([first, second]) == .expired(id: first.id))
}

@Test func menuBarExpiringIsTheSoonest() {
    let ok = login(remaining: 5 * 3600, now: now, name: "dev")
    let later = login(remaining: 25 * 60, now: now, name: "prod")
    let sooner = login(remaining: 19 * 60, now: now, name: "qa")

    #expect(status([ok, later, sooner]) == .expiring(id: sooner.id, remaining: 19 * 60))
}

@Test func menuBarOkIsTheSoonestFutureExpiry() {
    let later = login(remaining: 14 * 3600, now: now, name: "dev")
    let soonerRemaining: TimeInterval = 5 * 3600 + 13 * 60
    let sooner = login(remaining: soonerRemaining, now: now, name: "prod")

    #expect(status([later, noTimer, sooner]) == .ok(id: sooner.id, remaining: soonerRemaining))
}

@Test func menuBarSkipsStillValidLogins() {
    let ok = login(remaining: 5 * 3600, now: now)

    #expect(status([stillValid("analytics-dev"), ok]) == .ok(id: ok.id, remaining: 5 * 3600))
    #expect(status([stillValid("analytics-dev"), noTimer]) == .noTimer)
}

@Test func menuBarWithNoTimerAtAll() {
    #expect(status([]) == .noTimer)
    #expect(status([noTimer]) == .noTimer)
}
