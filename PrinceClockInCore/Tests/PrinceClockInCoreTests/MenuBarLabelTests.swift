import Foundation
import Testing
import PrinceClockInCore

private let british = Locale(identifier: "en_GB")
private let swedish = Locale(identifier: "sv_SE")
private let prod = Login(displayName: "prod", kind: .awsSSOSession(name: "prod"))
private let nineteenMinutes: TimeInterval = 19 * 60
private let fiveHoursThirteen: TimeInterval = 5 * 3600 + 13 * 60

private let thirtyMinutes: TimeInterval = 30 * 60

private func label(
    _ status: MenuBarStatus, locale: Locale = british, leadTime: TimeInterval = thirtyMinutes,
    updateVersion: String? = nil
) -> MenuBarLabel {
    menuBarLabel(for: status, logins: [prod], leadTime: leadTime, updateVersion: updateVersion, locale: locale)
}

@Suite struct MenuBarLabelTests {
    @Test func eachStateHasItsSymbol() {
        #expect(label(.loggingIn(BatchProgress(position: 1, total: 2))).symbolName == "clock.arrow.circlepath")
        #expect(label(.failure).symbolName == "exclamationmark.triangle")
        #expect(label(.expired(id: prod.id)).symbolName == "clock.badge.xmark")
        #expect(label(.expiring(id: prod.id, remaining: nineteenMinutes)).symbolName == "clock.badge.exclamationmark")
        #expect(label(.ok(id: prod.id, remaining: fiveHoursThirteen)).symbolName == "clock")
        #expect(label(.noTimer).symbolName == "clock")
    }

    @Test func textIsTheTimeLeftOrTheBatchProgress() {
        #expect(label(.loggingIn(BatchProgress(position: 1, total: 2))).text == "1 of 2")
        #expect(label(.expiring(id: prod.id, remaining: nineteenMinutes)).text == "19m")
        #expect(label(.ok(id: prod.id, remaining: fiveHoursThirteen)).text == "5h 13m")
        #expect(label(.ok(id: prod.id, remaining: fiveHoursThirteen), locale: swedish).text == "5\u{202F}h 13\u{202F}m")
    }

    @Test func statesWithoutTimeHaveNoText() {
        #expect(label(.failure).text == nil)
        #expect(label(.expired(id: prod.id)).text == nil)
        #expect(label(.noTimer).text == nil)
        #expect(label(.noTimer).widthSamples.isEmpty)
    }

    @Test func expiringReservesTheWidestFormUpToTheWarningTime() {
        let expiring = MenuBarStatus.expiring(id: prod.id, remaining: nineteenMinutes)
        let twoHours: TimeInterval = 2 * 3600

        #expect(label(expiring).widthSamples == ["<1m", "88m"])
        #expect(label(expiring, leadTime: 5 * 60).widthSamples == ["<1m", "8m"])
        #expect(label(expiring, leadTime: twoHours).widthSamples == ["<1m", "88m", "8h 88m"])
        #expect(label(expiring, locale: swedish, leadTime: twoHours).widthSamples
            == ["<1m", "88\u{202F}m", "8\u{202F}h 88\u{202F}m"])
    }

    @Test func okReservesBothTheHoursAndTheDaysForms() {
        let ok = MenuBarStatus.ok(id: prod.id, remaining: fiveHoursThirteen)

        #expect(label(ok).widthSamples == ["<1m", "88m", "88h 88m", "88d 88h"])
        #expect(label(ok, locale: swedish).widthSamples
            == ["<1m", "88\u{202F}m", "88\u{202F}h 88\u{202F}m", "88\u{202F}d 88\u{202F}h"])
    }

    @Test func loggingInReservesTwoDigitProgress() {
        #expect(label(.loggingIn(BatchProgress(position: 1, total: 2))).widthSamples == ["88 of 88"])
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
