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

@Test func statusText() {
    let now = at("2026-11-17T12:00:00Z")
    func text(_ remaining: TimeInterval) -> String {
        menuBarStatus([login(remaining: remaining, now: now)], now: now, leadTime: lead).text
    }

    #expect(text(51 * 3600) == "2d03h")
    #expect(text(24 * 3600) == "1d00h")
    #expect(text(2 * 3600 + 5 * 60) == "2h05")
    #expect(text(2 * 3600 + 5 * 60 + 59) == "2h05")
    #expect(text(45 * 60) == "45m")
    #expect(text(59 * 60 + 59) == "59m")
    #expect(text(59) == "<1m")
}

@Test func statusTextAtUnitBoundaries() {
    let now = at("2026-11-17T12:00:00Z")
    func text(_ remaining: TimeInterval) -> String {
        menuBarStatus([login(remaining: remaining, now: now)], now: now, leadTime: lead).text
    }

    #expect(text(3599) == "59m")
    #expect(text(3600) == "1h00")
    #expect(text(24 * 3600 - 1) == "23h59")
    #expect(text(24 * 3600) == "1d00h")
}

@Test func statusTextShowsSoonestUnexpiredLogin() {
    let now = at("2026-11-17T12:00:00Z")
    let logins = [
        login(remaining: 5 * 3600, now: now, name: "prod"),
        login(remaining: 2 * 3600, now: now, name: "dev"),
        login(remaining: -60, now: now, name: "old"),
        Login(displayName: "unknown", kind: .custom(command: nil)),
    ]

    #expect(menuBarStatus(logins, now: now, leadTime: lead).text == "2h00")
}

@Test func statusTextIsDashWithoutKnownUnexpiredLogin() {
    let now = at("2026-11-17T12:00:00Z")

    #expect(menuBarStatus([], now: now, leadTime: lead) == MenuBarStatus(text: "—", severity: .normal))
    #expect(menuBarStatus([Login(displayName: "x", kind: .custom(command: nil))], now: now, leadTime: lead).text == "—")
    let expired = menuBarStatus([login(remaining: -1, now: now)], now: now, leadTime: lead)
    #expect(expired == MenuBarStatus(text: "—", severity: .expired))
}

@Test func statusSeverity() {
    let now = at("2026-11-17T12:00:00Z")
    let ok = login(remaining: 5 * 3600, now: now)
    let expiring = login(remaining: 10 * 60, now: now)
    let expired = login(remaining: -60, now: now)

    #expect(menuBarStatus([ok], now: now, leadTime: lead).severity == .normal)
    #expect(menuBarStatus([ok, expiring], now: now, leadTime: lead).severity == .expiring)
    #expect(menuBarStatus([ok, expired], now: now, leadTime: lead).severity == .expired)
    #expect(menuBarStatus([expiring, expired], now: now, leadTime: lead).severity == .expired)
}

@Test func rowTextNamesEachState() {
    #expect(rowStateText(.ok(remaining: 2 * 3600 + 14 * 60 + 30)) == "2h14 left")
    #expect(rowStateText(.expiring(remaining: 25 * 60)) == "Expiring, 25m left")
    #expect(rowStateText(.expired) == "Expired")
    #expect(rowStateText(.unknown) == "No known expiry")
}

@Test func menuBarTextShowsBatchPositionWhileOneRuns() {
    let status = MenuBarStatus(text: "2h14", severity: .expiring)

    #expect(menuBarText(status, batch: nil) == "2h14")
    #expect(menuBarText(status, batch: BatchProgress(position: 2, total: 3)) == "2/3")
}
