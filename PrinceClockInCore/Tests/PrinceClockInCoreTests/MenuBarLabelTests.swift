import Foundation
import Testing
import PrinceClockInCore

private let british = Locale(identifier: "en_GB")
private let swedish = Locale(identifier: "sv_SE")
private let prod = Login(displayName: "prod", kind: .awsSSOSession(name: "prod"))
private let nineteenMinutes: TimeInterval = 19 * 60
private let fiveHoursThirteen: TimeInterval = 5 * 3600 + 13 * 60

private func label(
    _ status: MenuBarStatus, locale: Locale = british, updateVersion: String? = nil
) -> MenuBarLabel {
    menuBarLabel(for: status, logins: [prod], updateVersion: updateVersion, locale: locale)
}

@Suite struct MenuBarLabelTests {
    @Test func eachStateHasItsSymbol() {
        #expect(label(.loggingIn(BatchProgress(position: 1, total: 2))).symbolName == "clock.arrow.circlepath")
        #expect(label(.failure).symbolName == "clock.badge.xmark")
        #expect(label(.expired(id: prod.id)).symbolName == "clock.badge.xmark")
        #expect(label(.expiring(id: prod.id, remaining: nineteenMinutes)).symbolName == "clock.badge.exclamationmark")
        #expect(label(.ok(id: prod.id, remaining: fiveHoursThirteen)).symbolName == "clock")
        #expect(label(.loggedIn(id: prod.id)).symbolName == "clock")
        #expect(label(.noTimer).symbolName == "clock")
    }

    @Test func onlyLoggingInPulses() {
        #expect(label(.loggingIn(BatchProgress(position: 1, total: 2))).isPulsing)
        #expect(!label(.failure).isPulsing)
        #expect(!label(.expired(id: prod.id)).isPulsing)
        #expect(!label(.expiring(id: prod.id, remaining: nineteenMinutes)).isPulsing)
        #expect(!label(.ok(id: prod.id, remaining: fiveHoursThirteen)).isPulsing)
        #expect(!label(.noTimer).isPulsing)
    }

    @Test func voiceOverReadsOneLabelWithTheWideFormat() {
        #expect(label(.expiring(id: prod.id, remaining: nineteenMinutes)).accessibilityLabel
            == "PrinceClockIn, prod expiring in 19 minutes")
        #expect(label(.expiring(id: prod.id, remaining: nineteenMinutes), locale: swedish).accessibilityLabel
            == "PrinceClockIn, prod expiring in 19 minuter")
        #expect(label(.expiring(id: prod.id, remaining: 30)).accessibilityLabel
            == "PrinceClockIn, prod expiring in less than a minute")
        #expect(label(.ok(id: prod.id, remaining: fiveHoursThirteen)).accessibilityLabel
            == "PrinceClockIn, prod expires in 5 hours, 13 minutes")
        #expect(label(.expired(id: prod.id)).accessibilityLabel == "PrinceClockIn, prod expired")
        #expect(label(.loggingIn(BatchProgress(position: 1, total: 2))).accessibilityLabel
            == "PrinceClockIn, logging in, 1 of 2")
        #expect(label(.failure).accessibilityLabel == "PrinceClockIn, something failed")
        #expect(label(.loggedIn(id: prod.id)).accessibilityLabel == "PrinceClockIn, prod logged in")
        #expect(label(.noTimer).accessibilityLabel == "PrinceClockIn, no timer")
    }

    @Test func aWaitingUpdateAddsTheDotInAnyState() {
        let waiting = label(.noTimer, updateVersion: "1.0.1")

        #expect(waiting.showsUpdateDot)
        #expect(waiting.accessibilityLabel == "PrinceClockIn, no timer, update 1.0.1 available")
        #expect(label(.failure, updateVersion: "1.0.1").showsUpdateDot)
        #expect(!label(.noTimer).showsUpdateDot)
    }
}
