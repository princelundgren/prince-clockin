import Foundation
import Testing
import PrinceClockInCore
import UserNotifications

private let lead: TimeInterval = 30 * 60
private let british = Locale(identifier: "en_GB")

@Suite struct ExpiryNotificationsTests {
    @Test func notifiesWhenEnteringLeadTime() {
        let start = at("2026-11-17T12:00:00Z")
        let dev = login(remaining: lead + 1, now: start)

        #expect(expiryNotificationsDue([dev], now: start, leadTime: lead).isEmpty)
        #expect(expiryNotificationsDue([dev], now: start.addingTimeInterval(1), leadTime: lead) == [dev.id])
    }

    @Test func neverNotifiesAStillValidLogin() {
        let now = at("2026-11-17T12:00:00Z")
        let analytics = Login(
            displayName: "analytics-dev", kind: .databricksProfile(name: "analytics-dev", accountLevel: false),
            sessionLength: 3600, loginTime: now.addingTimeInterval(-7200),
            lastDatabricksAnswer: DatabricksCheckRecord(at: now, result: .valid))

        #expect(expiryNotificationsDue([analytics], now: now, leadTime: lead).isEmpty)
    }

    @Test func doesNotNotifyAgainSameLoginTime() {
        let now = at("2026-11-17T12:00:00Z")
        var dev = login(remaining: 10 * 60, now: now)
        dev.notifiedForExpiry = expiry(of: dev)

        #expect(expiryNotificationsDue([dev], now: now, leadTime: lead).isEmpty)
        #expect(expiryNotificationsDue([dev], now: now.addingTimeInterval(3600), leadTime: lead).isEmpty)
    }

    @Test func rearmsAfterNewLogin() {
        let now = at("2026-11-17T12:00:00Z")
        var dev = login(remaining: 10 * 60, now: now)
        dev.notifiedForExpiry = expiry(of: dev)

        dev.loginTime = now
        #expect(expiryNotificationsDue([dev], now: now, leadTime: lead).isEmpty)
        #expect(expiryNotificationsDue([dev], now: now.addingTimeInterval(7.5 * 3600), leadTime: lead) == [dev.id])
    }

    @Test func sleepAcrossTwoNotificationTimesGivesBoth() {
        let sleptAt = at("2026-11-17T12:00:00Z")
        let dev = login(remaining: 1 * 3600, now: sleptAt, name: "dev")
        let prod = login(remaining: 2 * 3600, now: sleptAt, name: "prod")
        let later = login(remaining: 6 * 3600, now: sleptAt, name: "analytics-dev")
        let logins = [dev, prod, later]

        #expect(expiryNotificationsDue(logins, now: sleptAt, leadTime: lead).isEmpty)
        #expect(expiryNotificationsDue(logins, now: sleptAt.addingTimeInterval(3 * 3600), leadTime: lead)
                == [dev.id, prod.id])
    }

    @Test func expiredWhileAppNotRunningIsIncludedOnce() {
        let launch = at("2026-11-18T08:00:00Z")
        var dev = login(remaining: -10 * 3600, now: launch)

        #expect(expiryNotificationsDue([dev], now: launch, leadTime: lead) == [dev.id])

        dev.notifiedForExpiry = expiry(of: dev)
        #expect(expiryNotificationsDue([dev], now: launch, leadTime: lead).isEmpty)
    }

    @Test func unknownTimerNeverNotifies() {
        let now = at("2026-11-17T12:00:00Z")
        let noTime = Login(displayName: "dev", kind: .awsSSOSession(name: "dev"), sessionLength: 8 * 3600)
        let noLength = Login(displayName: "prod", kind: .databricksProfile(name: "prod", accountLevel: false),
                             loginTime: now.addingTimeInterval(-30 * 24 * 3600))

        #expect(expiryNotificationsDue([noTime, noLength], now: now, leadTime: lead).isEmpty)
    }

    @Test func invalidatedLoginDoesNotNotify() {
        let now = at("2026-11-17T12:00:00Z")
        var dev = login(remaining: 10 * 60, now: now)
        dev.invalidatedAt = dev.loginTime
        var prod = login(remaining: 10 * 60, now: now, name: "prod")
        prod.invalidatedAt = now

        #expect(expiryNotificationsDue([dev, prod], now: now, leadTime: lead).isEmpty)
    }

    @Test func lengtheningSessionRearms() {
        let now = at("2026-11-17T12:00:00Z")
        var dev = login(remaining: 10 * 60, now: now)
        dev.notifiedForExpiry = expiry(of: dev)

        dev.sessionLength = (dev.sessionLength ?? 0) + 15 * 60
        #expect(expiryNotificationsDue([dev], now: now, leadTime: lead) == [dev.id])
    }

    @Test func contentNamesOneLoginInTitle() {
        let now = at("2026-11-17T12:00:00Z")
        let dev = login(remaining: 25 * 60, now: now)

        let content = expiryNotificationContent([dev], now: now, locale: british)

        #expect(content.title == "dev expires in 25m")
        #expect(content.ids == [dev.id])
    }

    @Test func contentSaysExpiredForExpiredLogin() {
        let now = at("2026-11-17T12:00:00Z")
        let dev = login(remaining: -60, now: now)
        var prod = login(remaining: 3600, now: now, name: "prod")
        prod.invalidatedAt = now

        #expect(expiryNotificationContent([dev], now: now, locale: british).title == "dev expired")
        #expect(expiryNotificationContent([prod], now: now, locale: british).title == "prod expired")
    }

    @Test func contentListsSeveral() {
        let now = at("2026-11-17T12:00:00Z")
        let dev = login(remaining: 25 * 60, now: now, name: "dev")
        let prod = login(remaining: -3600, now: now, name: "prod")

        let content = expiryNotificationContent([dev, prod], now: now, locale: british)

        #expect(content.title == "2 logins need logging in")
        #expect(content.body == "dev: expires in 25m\nprod: expired")
        #expect(content.ids == [dev.id, prod.id])
    }

    @Test func contentReadsEnglishTimesInASwedishRegion() {
        let now = at("2026-11-17T12:00:00Z")
        let dev = login(remaining: 5 * 3600 + 13 * 60, now: now)

        #expect(expiryNotificationContent([dev], now: now, locale: Locale(identifier: "en_SE")).title
                == "dev expires in 5h 13m")
    }

    @Test func customDoneNotificationPointsToTerminalOnlyWithACommand() {
        let vpn = Login(displayName: "vpn", kind: .custom(command: "vpn-login"))
        let manualVPN = Login(displayName: "vpn", kind: .custom(command: nil))

        #expect(customDoneContent(vpn)
            == NotificationText(title: "vpn is waiting in Terminal", body: "Finish the login there, then click Done."))
        #expect(customDoneContent(manualVPN)
            == NotificationText(title: "vpn is waiting for you", body: "Log in your own way, then click Done."))
    }

    @Test func onlyActionButtonsLogIn() {
        let dev = UUID()
        let prod = UUID()
        let ids = [dev.uuidString, prod.uuidString]

        #expect(notificationAction(actionIdentifier: NotificationActionID.logIn, loginIDs: ids) == .logIn([dev, prod]))
        #expect(notificationAction(actionIdentifier: NotificationActionID.done, loginIDs: [dev.uuidString])
            == .customDone(dev))
        #expect(notificationAction(actionIdentifier: UNNotificationDismissActionIdentifier, loginIDs: ids) == nil)
        #expect(notificationAction(actionIdentifier: NotificationActionID.logIn, loginIDs: ["not-a-uuid"]) == nil)
    }

    @Test func clickingTheNotificationOpensThePanel() {
        let ids = [UUID().uuidString]

        #expect(notificationAction(actionIdentifier: UNNotificationDefaultActionIdentifier, loginIDs: ids) == .openPanel)
        #expect(notificationAction(actionIdentifier: UNNotificationDefaultActionIdentifier, loginIDs: []) == .openPanel)
    }
}
