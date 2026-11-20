import Foundation
import Testing
import PrinceClockInCore

private let hour: TimeInterval = 3600
private let minute: TimeInterval = 60
private let now = at("2026-11-19T12:00:00Z")
private let british = Locale(identifier: "en_GB")
private let american = Locale(identifier: "en_US")
private let swedish = Locale(identifier: "sv_SE")

private func calendar(_ locale: Locale) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = locale
    calendar.timeZone = TimeZone(identifier: "Europe/Stockholm")!
    return calendar
}

private func aws(_ name: String = "dev", sessionLength: TimeInterval? = 8 * hour, loginTime: Date? = nil) -> Login {
    Login(displayName: name, kind: .awsSSOSession(name: name), sessionLength: sessionLength, loginTime: loginTime)
}

private func draft(_ login: Login = aws(), _ edit: (inout SetTimerDraft) -> Void = { _ in }) -> SetTimerDraft {
    var draft = SetTimerDraft(for: login, now: now, locale: british)
    edit(&draft)
    return draft
}

@Suite struct SetTimerTests {
    // MARK: A new draft

    @Test func aNewDraftExpiresInAnHourWithTheLoginsSessionLength() {
        let loggedIn = at("2026-11-19T09:00:00Z")
        let new = draft(aws(loginTime: loggedIn))

        #expect(new.mode == .expiresIn)
        #expect(new.hours == "1")
        #expect(new.minutes == "0")
        #expect(new.loggedInAt == loggedIn)
        #expect(new.sessionLength == .length(8 * hour))
    }

    @Test func aNewDraftWithoutALoginTimeIsLoggedInAtNow() {
        #expect(draft().loggedInAt == now)
    }

    @Test func anUnknownSessionLengthIsNoTimerUntilChosen() {
        let unknown = draft(aws(sessionLength: nil))

        #expect(unknown.sessionLength == .noTimer)
        #expect(unknown.entry(locale: british) == nil)
        #expect(unknown.check(now: now, locale: british) == .noSessionLength)
    }

    @Test func anUnlistedSessionLengthIsCustomInHours() {
        let unlisted = draft(aws(sessionLength: 10 * hour))

        #expect(unlisted.sessionLength == .custom)
        #expect(unlisted.customHours == "10")
        #expect(unlisted.entry(locale: british) == .expiresIn(hour, sessionLength: 10 * hour))
    }

    @Test func expiresInTakesHoursAndMinutes() {
        let entry = draft { $0.hours = "4"; $0.minutes = "30" }.entry(locale: british)

        #expect(entry == .expiresIn(4.5 * hour, sessionLength: 8 * hour))
    }

    @Test func anEmptyHoursOrMinutesFieldCountsAsZero() {
        #expect(draft { $0.hours = ""; $0.minutes = "45" }.entry(locale: british)
            == .expiresIn(45 * minute, sessionLength: 8 * hour))
        #expect(draft { $0.hours = " 2 "; $0.minutes = "" }.entry(locale: british)
            == .expiresIn(2 * hour, sessionLength: 8 * hour))
    }

    @Test func expiresInIsIncompleteWhenBothFieldsAreEmptyOrOneIsNotAWholeNumber() {
        #expect(draft { $0.hours = ""; $0.minutes = "" }.entry(locale: british) == nil)
        #expect(draft { $0.hours = "two" }.entry(locale: british) == nil)
        #expect(draft { $0.minutes = "1.5" }.entry(locale: british) == nil)
    }

    @Test func loggedInAtTakesTheTimeAndTheSessionLength() {
        let entry = draft {
            $0.mode = .loggedInAt
            $0.loggedInAt = at("2026-11-19T10:00:00Z")
            $0.sessionLength = .length(24 * hour)
        }.entry(locale: british)

        #expect(entry == .loggedInAt(at("2026-11-19T10:00:00Z"), sessionLength: 24 * hour))
    }

    @Test func aCustomSessionLengthIsANumberOfHoursInTheLocalesFormat() {
        #expect(draft { $0.sessionLength = .custom; $0.customHours = "36" }.entry(locale: british)
            == .expiresIn(hour, sessionLength: 36 * hour))
        var swedishDraft = SetTimerDraft(for: aws(), now: now, locale: swedish)
        swedishDraft.sessionLength = .custom
        swedishDraft.customHours = "1,5"
        #expect(swedishDraft.entry(locale: swedish) == .expiresIn(hour, sessionLength: 1.5 * hour))
    }

    @Test func aCustomSessionLengthThatIsEmptyOrNotPositiveIsIncomplete() {
        #expect(draft { $0.sessionLength = .custom; $0.customHours = "" }.entry(locale: british) == nil)
        #expect(draft { $0.sessionLength = .custom; $0.customHours = "0" }.entry(locale: british) == nil)
        #expect(draft { $0.sessionLength = .custom; $0.customHours = "-8" }.entry(locale: british) == nil)
    }

    @Test func aCustomSessionLengthWithAnythingAfterTheNumberIsIncomplete() {
        #expect(draft { $0.sessionLength = .custom; $0.customHours = "10h" }.entry(locale: british) == nil)
        var swedishDraft = SetTimerDraft(for: aws(), now: now, locale: swedish)
        swedishDraft.sessionLength = .custom
        swedishDraft.customHours = "1.5"
        #expect(swedishDraft.entry(locale: swedish) == nil)
    }

    @Test func aCustomSessionLengthThatIsNotFiniteIsIncomplete() {
        #expect(draft { $0.sessionLength = .custom; $0.customHours = "∞" }.entry(locale: british) == nil)
        #expect(draft { $0.sessionLength = .custom; $0.customHours = "1e400" }.entry(locale: british) == nil)
    }

    @Test func aCustomSessionLengthOverAYearIsRefused() {
        let huge = draft { $0.sessionLength = .custom; $0.customHours = "1e300" }

        #expect(huge.check(now: now, locale: british) == .refused(.sessionLengthTooLong))
        #expect(draft { $0.sessionLength = .custom; $0.customHours = "8761" }.check(now: now, locale: british)
            == .refused(.sessionLengthTooLong))
        #expect(draft { $0.sessionLength = .custom; $0.customHours = "8760" }.check(now: now, locale: british)
            == .ready(TimerSetting(loginTime: now.addingTimeInterval(hour - 8760 * hour), sessionLength: 8760 * hour)))
    }

    @Test func anUnlistedSessionLengthIsKeptExactlyUntilCustomIsEdited() {
        let twentyMinutes = draft(aws(sessionLength: 20 * minute)) { $0.mode = .loggedInAt; $0.loggedInAt = now }

        #expect(twentyMinutes.entry(locale: british) == .loggedInAt(now, sessionLength: 20 * minute))
        var edited = twentyMinutes
        edited.customHours = "2"
        #expect(edited.entry(locale: british) == .loggedInAt(now, sessionLength: 2 * hour))
    }

    // MARK: Expires In's ranges

    @Test func expiresInIsIncompleteWithNegativeHoursOrMinutesOutsideAnHour() {
        #expect(draft { $0.hours = "1"; $0.minutes = "-30" }.entry(locale: british) == nil)
        #expect(draft { $0.hours = "1"; $0.minutes = "90" }.entry(locale: british) == nil)
        #expect(draft { $0.hours = "-1"; $0.minutes = "30" }.entry(locale: british) == nil)
        #expect(draft { $0.hours = "0"; $0.minutes = "59" }.entry(locale: british)
            == .expiresIn(59 * minute, sessionLength: 8 * hour))
    }

    // MARK: The check: a login time and a session length

    @Test func expiresInBecomesALoginTimeThroughTheSessionLength() {
        let check = draft { $0.hours = "4"; $0.minutes = "30" }.check(now: now, locale: british)

        #expect(check == .ready(TimerSetting(loginTime: at("2026-11-19T08:30:00Z"), sessionLength: 8 * hour)))
    }

    @Test func loggedInAtIsTheLoginTime() {
        let check = draft { $0.mode = .loggedInAt; $0.loggedInAt = at("2026-11-19T10:00:00Z") }
            .check(now: now, locale: british)

        #expect(check == .ready(TimerSetting(loginTime: at("2026-11-19T10:00:00Z"), sessionLength: 8 * hour)))
    }

    @Test func theCheckRefusesWhatSetTimerRefuses() {
        #expect(draft { $0.hours = "9" }.check(now: now, locale: british) == .refused(.longerThanSessionLength))
        #expect(draft { $0.hours = "0"; $0.minutes = "0" }.check(now: now, locale: british)
            == .refused(.wouldAlreadyBeExpired))
        #expect(draft { $0.mode = .loggedInAt; $0.loggedInAt = now.addingTimeInterval(minute) }
            .check(now: now, locale: british) == .refused(.inFuture))
        #expect(draft { $0.mode = .loggedInAt; $0.loggedInAt = now.addingTimeInterval(-8 * hour) }
            .check(now: now, locale: british) == .refused(.wouldAlreadyBeExpired))
    }

    // MARK: The caption

    @Test func theCaptionSaysWhenItExpiresTodayAndThatTheLengthTimesTheNextLogin() {
        let ready = draft { $0.hours = "2" }.check(now: now, locale: british)

        #expect(setTimerCaption(for: ready, now: now, locale: british, calendar: calendar(british))
            == "Expires at 15:00. The session length times its next login.")
    }

    @Test func theCaptionFollowsATwelveHourRegion() {
        let ready = draft { $0.hours = "2" }.check(now: now, locale: american)

        #expect(setTimerCaption(for: ready, now: now, locale: american, calendar: calendar(american))
            == "Expires at 3:00\u{202F}PM. The session length times its next login.")
    }

    @Test func theCaptionNamesAnotherDay() throws {
        // `DateFormatter`'s relative formatting reads the real clock, so the fixture is built from it.
        let britishCalendar = calendar(british)
        let realNow = try #require(britishCalendar.dateInterval(of: .minute, for: .now)?.start)
        let tomorrow = try #require(britishCalendar.date(byAdding: .day, value: 1, to: realNow))
        let tomorrowAt0355 = try #require(britishCalendar.date(bySettingHour: 3, minute: 55, second: 0, of: tomorrow))
        let minutesLeft = Int(tomorrowAt0355.timeIntervalSince(realNow) / minute)
        var draft = SetTimerDraft(for: aws(sessionLength: 72 * hour), now: realNow, locale: british)
        draft.hours = "\(minutesLeft / 60)"
        draft.minutes = "\(minutesLeft % 60)"

        let ready = draft.check(now: realNow, locale: british)

        #expect(setTimerCaption(for: ready, now: realNow, locale: british, calendar: britishCalendar)
            == "Expires tomorrow at 03:55. The session length times its next login.")
    }

    @Test func aRefusalTakesTheCaptionsPlace() {
        let refused = draft { $0.hours = "9" }.check(now: now, locale: british)

        #expect(setTimerCaption(for: refused, now: now, locale: british, calendar: calendar(british))
            == "That's longer than the session length")
    }

    @Test func anIncompleteDraftHasNoCaption() {
        #expect(setTimerCaption(for: .incomplete, now: now, locale: british, calendar: calendar(british)) == nil)
    }

    @Test func noTimerChosenAsksForASessionLengthWhateverTheOtherFields() {
        let noLength = draft { $0.sessionLength = .noTimer; $0.hours = ""; $0.minutes = "x" }
            .check(now: now, locale: british)

        #expect(noLength == .noSessionLength)
        #expect(setTimerCaption(for: noLength, now: now, locale: british, calendar: calendar(british))
            == "Choose a session length")
    }

    @Test func aBadFieldWithASessionLengthStaysIncomplete() {
        #expect(draft { $0.minutes = "90" }.check(now: now, locale: british) == .incomplete)
        #expect(draft { $0.sessionLength = .custom; $0.customHours = "" }.check(now: now, locale: british)
            == .incomplete)
    }
}
