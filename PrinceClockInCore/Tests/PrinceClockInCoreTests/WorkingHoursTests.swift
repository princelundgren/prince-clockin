import Foundation
import Testing
import PrinceClockInCore

/// 2026-11-16 is a Monday, 2026-11-21 a Saturday.
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private let officeHours = WorkingHours(isOn: true)
private let nightShift = WorkingHours(isOn: true, startMinute: 22 * 60, endMinute: 6 * 60)

private func allows(_ hours: WorkingHours, _ iso: String, calendar: Calendar = utc) -> Bool {
    hours.allowsNotifying(at: at(iso), calendar: calendar)
}

private func next(_ hours: WorkingHours, _ iso: String, calendar: Calendar = utc) -> Date? {
    hours.nextNotifyingTime(onOrAfter: at(iso), calendar: calendar)
}

@Test func offAllowsEveryMoment() {
    let off = WorkingHours()

    #expect(allows(off, "2026-11-21T03:00:00Z"))
    #expect(next(off, "2026-11-21T03:00:00Z") == at("2026-11-21T03:00:00Z"))
}

@Test func dayHoursIncludeTheirStartAndExcludeTheirEnd() {
    #expect(!allows(officeHours, "2026-11-16T08:59:59Z"))
    #expect(allows(officeHours, "2026-11-16T09:00:00Z"))
    #expect(allows(officeHours, "2026-11-16T16:59:59Z"))
    #expect(!allows(officeHours, "2026-11-16T17:00:00Z"))
}

@Test func aDayNotPickedHoldsAllDay() {
    #expect(!allows(officeHours, "2026-11-21T12:00:00Z"))
}

@Test func outsideTheHoursTheNextStartIsTheNextPickedDay() {
    #expect(next(officeHours, "2026-11-16T07:00:00Z") == at("2026-11-16T09:00:00Z"))
    #expect(next(officeHours, "2026-11-16T18:00:00Z") == at("2026-11-17T09:00:00Z"))
    #expect(next(officeHours, "2026-11-20T18:00:00Z") == at("2026-11-23T09:00:00Z"))
}

@Test func insideTheHoursTheNextNotifyingTimeIsNow() {
    #expect(next(officeHours, "2026-11-16T12:34:56Z") == at("2026-11-16T12:34:56Z"))
}

@Test func hoursPastMidnightBelongToTheDayTheyStart() {
    #expect(allows(nightShift, "2026-11-20T23:00:00Z"))
    #expect(allows(nightShift, "2026-11-21T05:59:59Z"))
    #expect(!allows(nightShift, "2026-11-21T06:00:00Z"))
    #expect(!allows(nightShift, "2026-11-21T23:00:00Z"))
    #expect(!allows(nightShift, "2026-11-16T03:00:00Z"))
    #expect(next(nightShift, "2026-11-21T06:00:00Z") == at("2026-11-23T22:00:00Z"))
}

@Test func equalStartAndEndMakeADayLongSpan() {
    let allDay = WorkingHours(isOn: true, startMinute: 9 * 60, endMinute: 9 * 60)

    #expect(allows(allDay, "2026-11-20T09:00:00Z"))
    #expect(allows(allDay, "2026-11-21T08:59:59Z"))
    #expect(!allows(allDay, "2026-11-21T09:00:00Z"))
}

@Test func hoursThatCanHoldNothingAllowEveryMoment() {
    let noDay = WorkingHours(isOn: true, weekdays: [])
    let unknownDay = WorkingHours(isOn: true, weekdays: [9])
    let startOutsideTheDay = WorkingHours(isOn: true, startMinute: 2000)
    let endOutsideTheDay = WorkingHours(isOn: true, endMinute: -1)

    for hours in [noDay, unknownDay, startOutsideTheDay, endOutsideTheDay] {
        #expect(allows(hours, "2026-11-21T03:00:00Z"))
        #expect(next(hours, "2026-11-21T03:00:00Z") == at("2026-11-21T03:00:00Z"))
    }
}

@Test func hoursAreReadInTheCalendarsTimeZone() {
    var stockholm = Calendar(identifier: .gregorian)
    stockholm.timeZone = TimeZone(identifier: "Europe/Stockholm")!

    #expect(allows(officeHours, "2026-11-16T08:30:00Z", calendar: stockholm))
    #expect(!allows(officeHours, "2026-11-16T16:30:00Z", calendar: stockholm))
    #expect(next(officeHours, "2026-11-16T07:00:00Z", calendar: stockholm) == at("2026-11-16T08:00:00Z"))
}

@Test func theStartAfterAClockChangeIsTheLocalStart() {
    var stockholm = Calendar(identifier: .gregorian)
    stockholm.timeZone = TimeZone(identifier: "Europe/Stockholm")!

    // Stockholm moves from UTC+2 to UTC+1 overnight on 2026-10-25, a Sunday.
    #expect(next(officeHours, "2026-10-23T16:00:00Z", calendar: stockholm) == at("2026-10-26T08:00:00Z"))
    #expect(allows(officeHours, "2026-10-26T08:00:00Z", calendar: stockholm))
}

@Test func whereverATickFindsNothingToSendItsNextNotifyingTimeIsLater() {
    var stockholm = Calendar(identifier: .gregorian)
    stockholm.timeZone = TimeZone(identifier: "Europe/Stockholm")!
    let hourSets = [
        officeHours, nightShift, WorkingHours(isOn: true, startMinute: 9 * 60, endMinute: 9 * 60),
        // Starts inside the hour Stockholm skips on 2026-03-29.
        WorkingHours(isOn: true, startMinute: 2 * 60 + 30, endMinute: 2 * 60 + 45, weekdays: Set(1...7)),
    ]
    for week in [at("2026-10-23T00:00:00Z"), at("2026-03-26T00:00:00Z")] {
        for hours in hourSets {
            for quarter in 0..<(10 * 24 * 4) {
                let moment = week.addingTimeInterval(TimeInterval(quarter) * 15 * 60)
                guard !hours.allowsNotifying(at: moment, calendar: stockholm) else { continue }
                let notifying = hours.nextNotifyingTime(onOrAfter: moment, calendar: stockholm)
                #expect(notifying != nil)
                if let notifying {
                    #expect(notifying > moment)
                    #expect(hours.allowsNotifying(at: notifying, calendar: stockholm))
                }
            }
        }
    }
}

@Test func weekdaysFollowTheCalendarsFirstWeekday() {
    var mondayFirst = utc
    mondayFirst.firstWeekday = 2

    #expect(weekdaysInDisplayOrder(calendar: mondayFirst) == [2, 3, 4, 5, 6, 7, 1])
    #expect(weekdaysInDisplayOrder(calendar: utc) == [1, 2, 3, 4, 5, 6, 7])
}

@Test func workingHoursEncodeTheirWeekdaysInOrderAndDecode() throws {
    let hours = WorkingHours(isOn: true, startMinute: 8 * 60, endMinute: 16 * 60 + 30, weekdays: [6, 2, 4])

    let data = try JSONEncoder().encode(hours)

    let weekdays = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])["weekdays"]
    #expect(weekdays as? [Int] == [2, 4, 6])
    #expect(try JSONDecoder().decode(WorkingHours.self, from: data) == hours)
}
