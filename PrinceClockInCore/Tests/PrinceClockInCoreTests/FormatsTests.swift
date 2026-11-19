import Foundation
import Testing
import PrinceClockInCore

private let hour: TimeInterval = 3600
private let minute: TimeInterval = 60
private let british = Locale(identifier: "en_GB")
private let swedish = Locale(identifier: "sv_SE")
private let stockholm = TimeZone(identifier: "Europe/Stockholm")!

private func calendar(_ locale: Locale) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = locale
    calendar.timeZone = stockholm
    return calendar
}

@Suite struct FormatsTests {
    @Test func timeLeftIsNarrowWithAtMostTwoUnits() {
        #expect(timeLeftText(5 * hour + 13 * minute, locale: british) == "5h 13m")
        #expect(timeLeftText(14 * hour + 5 * minute, locale: british) == "14h 5m")
        #expect(timeLeftText(65 * hour, locale: british) == "2d 17h")
        // sv_SE joins each number to its unit with a narrow no-break space (U+202F).
        #expect(timeLeftText(5 * hour + 13 * minute, locale: swedish) == "5\u{202F}h 13\u{202F}m")
        #expect(timeLeftText(14 * hour + 5 * minute, locale: swedish) == "14\u{202F}h 5\u{202F}m")
        #expect(timeLeftText(65 * hour, locale: swedish) == "2\u{202F}d 17\u{202F}h")
    }

    @Test func timeLeftRoundsDown() {
        #expect(timeLeftText(5 * hour + 13 * minute + 59, locale: british) == "5h 13m")
        #expect(timeLeftText(65 * hour + 59 * minute, locale: british) == "2d 17h")
        #expect(timeLeftText(19 * minute + 30, locale: british) == "19m")
    }

    @Test func underAMinuteLeftReadsLessThanAMinute() {
        #expect(timeLeftText(59, locale: british) == "<1m")
        #expect(timeLeftText(0.5, locale: british) == "<1m")
        #expect(timeLeftText(59, locale: swedish) == "<1m")
        #expect(spokenTimeLeftText(59, locale: british) == "less than a minute")
        #expect(timeLeftText(60, locale: british) == "1m")
    }

    @Test func spokenTimeLeftIsWide() {
        #expect(spokenTimeLeftText(5 * hour + 13 * minute + 59, locale: british) == "5 hours, 13 minutes")
        #expect(spokenTimeLeftText(5 * hour + 13 * minute, locale: swedish) == "5 timmar, 13 minuter")
    }

    @Test func clockTimeIsShortened() {
        let time = at("2026-11-19T13:02:00Z")

        #expect(clockTimeText(time, locale: british, calendar: calendar(british)) == "14:02")
        #expect(clockTimeText(time, locale: swedish, calendar: calendar(swedish)) == "14:02")
    }

    @Test func timeOnAnotherDayIsRelative() throws {
        // `DateFormatter`'s relative formatting reads the real clock, so the fixture is built from it.
        let britishCalendar = calendar(british)
        let tomorrow = try #require(britishCalendar.date(byAdding: .day, value: 1, to: .now))
        let tomorrowAt0355 = try #require(britishCalendar.date(bySettingHour: 3, minute: 55, second: 0, of: tomorrow))

        #expect(dayAndTimeText(tomorrowAt0355, locale: british, calendar: britishCalendar)
            == "tomorrow at 03:55")
        #expect(dayAndTimeText(tomorrowAt0355, locale: swedish, calendar: calendar(swedish))
            == "imorgon 03:55")
    }

    @Test func batchProgressHasOneForm() {
        #expect(batchProgressText(BatchProgress(position: 1, total: 2)) == "1 of 2")
    }
}
