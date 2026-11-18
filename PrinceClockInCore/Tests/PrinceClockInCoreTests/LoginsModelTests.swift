import Foundation
import Testing
import PrinceClockInCore

private let hour: TimeInterval = 3600

private func databricks(_ name: String, sessionLength: TimeInterval? = 24 * hour, loginTime: Date? = nil) -> Login {
    Login(
        displayName: name, kind: .databricksProfile(name: name, accountLevel: false),
        sessionLength: sessionLength, loginTime: loginTime)
}

private func model(_ logins: [Login], presets: [Preset] = []) -> LoginsModel {
    LoginsModel(state: AppState(logins: logins, presets: presets))
}

@Suite struct LoginsModelTests {
    @Test func succeededSetsLoginTime() {
        let now = at("2026-11-17T12:00:00Z")
        let dev = login(remaining: -hour, now: now)
        var logins = model([dev])

        logins.apply(.succeeded(id: dev.id, at: now.addingTimeInterval(0.7)))

        #expect(logins.state.logins[0].loginTime == now)
    }

    @Test func failureLeavesTimer() {
        let now = at("2026-11-17T12:00:00Z")
        let dev = login(remaining: hour, now: now)
        var logins = model([dev])

        logins.apply(.failed(id: dev.id, reason: .timedOut))
        logins.apply(.failed(id: dev.id, reason: .cancelled))

        #expect(logins == model([dev]))
    }

    @Test func awsNewLoginSetsLoginTime() {
        let now = at("2026-11-17T12:00:00Z")
        let dev = login(remaining: -hour, now: now)
        var logins = model([dev])

        logins.apply(.newLogin(at: now.addingTimeInterval(-60)), login: dev.id, now: now)

        #expect(logins.state.logins[0].loginTime == now.addingTimeInterval(-60))
    }

    @Test func awsLoggedOutExpires() {
        let now = at("2026-11-17T12:00:00Z")
        let dev = login(remaining: 4 * hour, now: now)
        var logins = model([dev])

        logins.apply(.loggedOut, login: dev.id, now: now)

        #expect(logins.state.logins[0].invalidatedAt == now)
        #expect(timerState(for: logins.state.logins[0], now: now, leadTime: 0) == .expired)
    }

    @Test func possibleLoginAsksAndConfirmSetsLoginTime() {
        let now = at("2026-11-17T12:00:00Z")
        let rewrite = at("2026-11-17T09:47:00Z")
        let dev = login(remaining: 10 * 60, now: now)
        var logins = model([dev])

        logins.apply(.possibleLogin(at: rewrite), login: dev.id, now: now)
        #expect(logins.possibleLogins == [dev.id: rewrite])
        #expect(logins.state.logins[0].loginTime == dev.loginTime)

        logins.confirmPossibleLogin(id: dev.id)
        #expect(logins.state.logins[0].loginTime == rewrite)
        #expect(logins.possibleLogins.isEmpty)
    }

    @Test func setTimerClearsPossibleLogin() throws {
        let now = at("2026-11-17T12:00:00Z")
        let rewrite = at("2026-11-17T09:47:00Z")
        let dev = login(remaining: 10 * 60, now: now)
        var asked = model([dev])
        asked.apply(.possibleLogin(at: rewrite), login: dev.id, now: now)

        var bySetTimer = asked
        try bySetTimer.setExpiry(id: dev.id, expiresAt: at("2026-11-17T16:00:00Z"), now: now)
        #expect(bySetTimer.state.logins[0].loginTime == at("2026-11-17T08:00:00Z"))
        #expect(bySetTimer.possibleLogins.isEmpty)

        var byLoggedInNow = asked
        byLoggedInNow.markLoggedInNow(id: dev.id, now: now)
        #expect(byLoggedInNow.state.logins[0].loginTime == now)
        #expect(byLoggedInNow.possibleLogins.isEmpty)

        var bySucceeded = asked
        bySucceeded.apply(.succeeded(id: dev.id, at: now))
        #expect(bySucceeded.possibleLogins.isEmpty)
    }

    @Test func setExpiryInPastIsRefusedAndKeepsQuestion() {
        let now = at("2026-11-17T12:00:00Z")
        let dev = login(remaining: 10 * 60, now: now)
        var logins = model([dev])
        logins.apply(.possibleLogin(at: now), login: dev.id, now: now)
        let before = logins

        #expect(throws: TimerError.expiryInPast) {
            try logins.setExpiry(id: dev.id, expiresAt: now.addingTimeInterval(-60), now: now)
        }
        #expect(logins == before)
    }

    @Test func databricksInvalidExpires() {
        let now = at("2026-11-17T12:00:00Z")
        let prod = databricks("prod", loginTime: now.addingTimeInterval(-hour))
        var logins = model([prod])

        logins.apply(.invalid, login: prod.id, now: now)

        #expect(logins.state.logins[0].invalidatedAt == now)
        #expect(timerState(for: logins.state.logins[0], now: now, leadTime: 0) == .expired)
    }

    @Test func databricksInvalidThenValidIsLogin() {
        let invalidAt = at("2026-11-17T12:00:00Z")
        let validAt = invalidAt.addingTimeInterval(10 * 60)
        let prod = databricks("prod", loginTime: invalidAt.addingTimeInterval(-hour))
        var logins = model([prod])

        logins.apply(.invalid, login: prod.id, now: invalidAt)
        logins.apply(.valid, login: prod.id, now: validAt)

        #expect(logins.state.logins[0].loginTime == validAt)
        #expect(timerState(for: logins.state.logins[0], now: validAt, leadTime: 0) == .ok(remaining: 24 * hour))
    }

    @Test func databricksValidWhileTimerExpiredFlagsBoth() {
        let now = at("2026-11-17T12:00:00Z")
        let prod = databricks("prod", sessionLength: hour, loginTime: now.addingTimeInterval(-2 * hour))
        let dev = databricks("dev", loginTime: now.addingTimeInterval(-hour))
        var logins = model([prod, dev])

        logins.apply(.valid, login: prod.id, now: now)
        logins.apply(.valid, login: dev.id, now: now)

        #expect(logins.validWhileExpired == [prod.id])
        #expect(logins.state == model([prod, dev]).state)
    }

    @Test func takeWarningsMarksAndPersists() throws {
        let now = at("2026-11-17T12:00:00Z")
        let dev = login(remaining: 10 * 60, now: now)
        let prod = login(remaining: 4 * hour, now: now, name: "prod")
        var logins = model([dev, prod])

        #expect(logins.takeWarnings(now: now) == [dev.id])
        #expect(logins.takeWarnings(now: now).isEmpty)
        #expect(logins.state.logins[0].warnedForExpiry == expiry(of: dev))
        #expect(logins.state.logins[1].warnedForExpiry == nil)
    }

    @Test func expiringSelection() {
        let now = at("2026-11-17T12:00:00Z")
        let ok = login(remaining: 4 * hour, now: now, name: "dev")
        let expiring = login(remaining: 10 * 60, now: now, name: "prod")
        let expired = login(remaining: -hour, now: now, name: "analytics-dev")
        let unknown = databricks("analytics-prod", sessionLength: nil)

        let selected = model([ok, expiring, expired, unknown]).expiringOrExpired(now: now)

        #expect(selected.map(\.id) == [expiring.id, expired.id])
    }

    @Test func presetSkipsDeletedLogins() {
        let now = at("2026-11-17T12:00:00Z")
        let dev = login(remaining: hour, now: now, name: "dev")
        let prod = databricks("prod")
        let preset = Preset(name: "dev + prod", loginIDs: [prod.id, UUID(), dev.id])

        let logins = model([dev, prod], presets: [preset]).logins(in: preset)

        #expect(logins.map(\.id) == [prod.id, dev.id])
    }

    @Test func databricksSelections() {
        let now = at("2026-11-17T12:00:00Z")
        let dev = login(remaining: hour, now: now, name: "dev")
        let prod = databricks("prod")
        let analytics = databricks("analytics-dev")
        let logins = model([dev, prod, analytics])

        #expect(logins.databricksLogins(among: [analytics.id, dev.id, UUID()]).map(\.id) == [analytics.id])
        #expect(logins.checkNowTargets().map(\.id) == [prod.id, analytics.id])
    }
}
