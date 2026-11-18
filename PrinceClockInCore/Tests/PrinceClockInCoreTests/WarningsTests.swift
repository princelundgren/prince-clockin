import Foundation
import Testing
import PrinceClockInCore
import UserNotifications

private let lead: TimeInterval = 30 * 60

@Suite struct WarningsTests {
    @Test func warnsWhenEnteringLeadTime() {
        let start = at("2026-11-17T12:00:00Z")
        let dev = login(remaining: lead + 1, now: start)

        #expect(warningsDue([dev], now: start, leadTime: lead).isEmpty)
        #expect(warningsDue([dev], now: start.addingTimeInterval(1), leadTime: lead) == [dev.id])
    }

    @Test func doesNotWarnAgainSameLoginTime() {
        let now = at("2026-11-17T12:00:00Z")
        var dev = login(remaining: 10 * 60, now: now)
        dev.warnedForExpiry = expiry(of: dev)

        #expect(warningsDue([dev], now: now, leadTime: lead).isEmpty)
        #expect(warningsDue([dev], now: now.addingTimeInterval(3600), leadTime: lead).isEmpty)
    }

    @Test func rearmsAfterNewLogin() {
        let now = at("2026-11-17T12:00:00Z")
        var dev = login(remaining: 10 * 60, now: now)
        dev.warnedForExpiry = expiry(of: dev)

        dev.loginTime = now
        #expect(warningsDue([dev], now: now, leadTime: lead).isEmpty)
        #expect(warningsDue([dev], now: now.addingTimeInterval(7.5 * 3600), leadTime: lead) == [dev.id])
    }

    @Test func sleepAcrossTwoWarningsGivesBoth() {
        let sleptAt = at("2026-11-17T12:00:00Z")
        let dev = login(remaining: 1 * 3600, now: sleptAt, name: "dev")
        let prod = login(remaining: 2 * 3600, now: sleptAt, name: "prod")
        let later = login(remaining: 6 * 3600, now: sleptAt, name: "analytics-dev")
        let logins = [dev, prod, later]

        #expect(warningsDue(logins, now: sleptAt, leadTime: lead).isEmpty)
        #expect(warningsDue(logins, now: sleptAt.addingTimeInterval(3 * 3600), leadTime: lead) == [dev.id, prod.id])
    }

    @Test func expiredWhileAppNotRunningIsIncludedOnce() {
        let launch = at("2026-11-18T08:00:00Z")
        var dev = login(remaining: -10 * 3600, now: launch)

        #expect(warningsDue([dev], now: launch, leadTime: lead) == [dev.id])

        dev.warnedForExpiry = expiry(of: dev)
        #expect(warningsDue([dev], now: launch, leadTime: lead).isEmpty)
    }

    @Test func unknownTimerNeverWarns() {
        let now = at("2026-11-17T12:00:00Z")
        let noTime = Login(displayName: "dev", kind: .awsSSOSession(name: "dev"), sessionLength: 8 * 3600)
        let noLength = Login(displayName: "prod", kind: .databricksProfile(name: "prod", accountLevel: false),
                             loginTime: now.addingTimeInterval(-30 * 24 * 3600))

        #expect(warningsDue([noTime, noLength], now: now, leadTime: lead).isEmpty)
    }

    @Test func invalidatedLoginDoesNotWarn() {
        let now = at("2026-11-17T12:00:00Z")
        var dev = login(remaining: 10 * 60, now: now)
        dev.invalidatedAt = dev.loginTime
        var prod = login(remaining: 10 * 60, now: now, name: "prod")
        prod.invalidatedAt = now

        #expect(warningsDue([dev, prod], now: now, leadTime: lead).isEmpty)
    }

    @Test func lengtheningSessionRearms() {
        let now = at("2026-11-17T12:00:00Z")
        var dev = login(remaining: 10 * 60, now: now)
        dev.warnedForExpiry = expiry(of: dev)

        dev.sessionLength = (dev.sessionLength ?? 0) + 15 * 60
        #expect(warningsDue([dev], now: now, leadTime: lead) == [dev.id])
    }

    @Test func contentNamesOneLoginInTitle() {
        let now = at("2026-11-17T12:00:00Z")
        let dev = login(remaining: 25 * 60, now: now)

        let content = warningContent([dev], now: now)

        #expect(content.title == "dev expires in 25m")
        #expect(content.ids == [dev.id])
    }

    @Test func contentSaysExpiredForExpiredLogin() {
        let now = at("2026-11-17T12:00:00Z")
        let dev = login(remaining: -60, now: now)
        var prod = login(remaining: 3600, now: now, name: "prod")
        prod.invalidatedAt = now

        #expect(warningContent([dev], now: now).title == "dev expired")
        #expect(warningContent([prod], now: now).title == "prod expired")
    }

    @Test func contentListsSeveral() {
        let now = at("2026-11-17T12:00:00Z")
        let dev = login(remaining: 25 * 60, now: now, name: "dev")
        let prod = login(remaining: -3600, now: now, name: "prod")

        let content = warningContent([dev, prod], now: now)

        #expect(content.title == "2 logins need logging in")
        #expect(content.body == "dev: expires in 25m\nprod: expired")
        #expect(content.ids == [dev.id, prod.id])
    }

    @Test func onlyActionButtonsGiveActions() {
        let dev = UUID()
        let prod = UUID()
        let ids = [dev.uuidString, prod.uuidString]

        #expect(notificationAction(actionIdentifier: NotificationActionID.logIn, loginIDs: ids) == .logIn([dev, prod]))
        #expect(notificationAction(actionIdentifier: NotificationActionID.done, loginIDs: [dev.uuidString])
            == .customDone(dev))
        #expect(notificationAction(actionIdentifier: UNNotificationDefaultActionIdentifier, loginIDs: ids) == nil)
        #expect(notificationAction(actionIdentifier: UNNotificationDismissActionIdentifier, loginIDs: ids) == nil)
        #expect(notificationAction(actionIdentifier: NotificationActionID.logIn, loginIDs: ["not-a-uuid"]) == nil)
    }
}
