import Foundation
import Testing
import PrinceClockInCore

private let hour: TimeInterval = 3600
private let british = Locale(identifier: "en_GB")
private let swedish = Locale(identifier: "sv_SE")

@Suite struct SessionLengthTextTests {
    // MARK: What the field stores

    @Test func hoursInTheLocalesFormatAreStoredRoundedDownToWholeSeconds() throws {
        #expect(try sessionLength(fieldText: "900", locale: british) == 900 * hour)
        #expect(try sessionLength(fieldText: " 1.5 ", locale: british) == 1.5 * hour)
        #expect(try sessionLength(fieldText: "1,5", locale: swedish) == 1.5 * hour)
    }

    @Test func emptyTextMakesTheLengthUnknown() throws {
        #expect(try sessionLength(fieldText: "", locale: british) == nil)
        #expect(try sessionLength(fieldText: "  ", locale: british) == nil)
    }

    @Test func textThatIsNotAPositiveNumberOfHoursIsRefused() {
        for text in ["abc", "10abc", "0", "-5", "∞", "1e400", "0.0001"] {
            #expect(throws: SessionLengthRefusal.notANumberOfHours) {
                try sessionLength(fieldText: text, locale: british)
            }
        }
        #expect(throws: SessionLengthRefusal.notANumberOfHours) {
            try sessionLength(fieldText: "1.5", locale: swedish)
        }
    }

    @Test func groupingSeparatorsReadOnlyWhereTheLocaleGroupsDigits() throws {
        let american = Locale(identifier: "en_US")

        #expect(try sessionLength(fieldText: "1,000", locale: british) == 1000 * hour)
        #expect(try sessionLength(fieldText: "1,000", locale: american) == 1000 * hour)
        #expect(try sessionLength(fieldText: "1 000", locale: swedish) == 1000 * hour)
        #expect(try sessionLength(fieldText: "1\u{00A0}000", locale: swedish) == 1000 * hour)
        #expect(try sessionLength(fieldText: "1\u{202F}000", locale: swedish) == 1000 * hour)
        for (text, locale) in [("1,5", british), ("1,5", american), ("10,00", british), ("1.000", swedish)] {
            #expect(throws: SessionLengthRefusal.notANumberOfHours) {
                try sessionLength(fieldText: text, locale: locale)
            }
        }
    }

    @Test func aLengthOverAYearIsRefusedAndAYearIsNot() throws {
        for text in ["9000", "8761", "1e300"] {
            #expect(throws: SessionLengthRefusal.tooLong) {
                try sessionLength(fieldText: text, locale: british)
            }
        }
        #expect(try sessionLength(fieldText: "8760", locale: british) == maximumSessionLength)
    }

    @Test func aLengthUnderAMinuteIsRefusedAndAMinuteIsNot() throws {
        for text in ["0.01", "0.016"] {
            #expect(throws: SessionLengthRefusal.tooShort) {
                try sessionLength(fieldText: text, locale: british)
            }
        }
        #expect(try sessionLength(fieldText: "0.016667", locale: british) == 60)
    }

    @Test func refusalsCarryTheirCopy() {
        #expect(SessionLengthRefusal.notANumberOfHours.message == "Enter a number of hours")
        #expect(SessionLengthRefusal.tooLong.message == TimerError.sessionLengthTooLong.message)
        #expect(SessionLengthRefusal.tooShort.message == TimerError.sessionLengthUnderAMinute.message)
    }

    // MARK: What the field shows

    @Test func theFieldShowsTheLengthInHoursOrNothingWhenUnknown() {
        #expect(sessionLengthHoursText(8 * hour, locale: british) == "8")
        #expect(sessionLengthHoursText(1.5 * hour, locale: swedish) == "1,5")
        #expect(sessionLengthHoursText(10_000 * hour, locale: british) == "10000")
        #expect(sessionLengthHoursText(nil, locale: british) == "")
    }

    @Test func theShownTextReadsBackAsTheSameWholeSeconds() throws {
        let lengths: [TimeInterval] = [20 * 60, 25 * 60, 61, 7 * hour + 13 * 60 + 7, maximumSessionLength]
        for locale in [british, swedish] {
            for length in lengths {
                let text = sessionLengthHoursText(length, locale: locale)
                #expect(try sessionLength(fieldText: text, locale: locale) == length, "\(text)")
            }
        }
        #expect(sessionLengthHoursText(20 * 60, locale: british) == "0.333333")
    }
}
