import Foundation

/// The hours of the week in which expiry notifications are sent, when the user turns them on. A
/// notification that falls due outside them waits for the next start.
public struct WorkingHours: Equatable, Sendable {
    public static let minutesPerDay = 24 * 60
    /// Monday to Friday, as `Calendar` numbers weekdays: 1 is Sunday, 7 Saturday.
    public static let defaultWeekdays: Set<Int> = [2, 3, 4, 5, 6]

    public var isOn: Bool
    /// Minutes after midnight the hours start, below `minutesPerDay`.
    public var startMinute: Int
    /// Minutes after midnight the hours end. At or before `startMinute`, they end on the next day.
    public var endMinute: Int
    /// The weekdays the hours start on, numbered as `Calendar` numbers them.
    public var weekdays: Set<Int>

    /// Off, 09:00 to 17:00, Monday to Friday.
    public init(
        isOn: Bool = false, startMinute: Int = 9 * 60, endMinute: Int = 17 * 60,
        weekdays: Set<Int> = WorkingHours.defaultWeekdays
    ) {
        self.isOn = isOn
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.weekdays = weekdays
    }

    /// Whether a notification may be sent at `date`, read in `calendar`'s time zone: always while
    /// the hours are off or can't hold one (no weekday, or a time outside the day, as only a
    /// hand-edited file can have), else only inside them. Hours that end at or before they start
    /// run past midnight, so equal start and end make a 24-hour span.
    public func allowsNotifying(at date: Date, calendar: Calendar) -> Bool {
        guard canHold else { return true }
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday, let hour = parts.hour, let minute = parts.minute else { return true }
        let minuteOfDay = hour * 60 + minute
        if startMinute < endMinute {
            return weekdays.contains(weekday) && (startMinute..<endMinute).contains(minuteOfDay)
        }
        let startedToday = weekdays.contains(weekday) && minuteOfDay >= startMinute
        let startedYesterday = weekdays.contains(previousWeekday(weekday)) && minuteOfDay < endMinute
        return startedToday || startedYesterday
    }

    /// The first moment at or after `date` when a notification may be sent: `date` itself when
    /// `allowsNotifying(at:calendar:)` holds, else the next start of the hours that it allows, which
    /// skips a start in an hour a clock change leaves out, or `nil` when the calendar finds none in
    /// the coming two weeks.
    public func nextNotifyingTime(onOrAfter date: Date, calendar: Calendar) -> Date? {
        if allowsNotifying(at: date, calendar: calendar) { return date }
        let start = DateComponents(hour: startMinute / 60, minute: startMinute % 60)
        var candidate = date
        // Fourteen starts in a row fall twice on every weekday, and `canHold` names one of them; a
        // clock change skips a start at most once in that span.
        for _ in 0..<14 {
            guard
                let next = calendar.nextDate(
                    after: candidate, matching: start, matchingPolicy: .nextTime, direction: .forward)
            else { return nil }
            if allowsNotifying(at: next, calendar: calendar) { return next }
            candidate = next
        }
        return nil
    }

    private var canHold: Bool {
        let day = 0..<Self.minutesPerDay
        return isOn && weekdays.contains(where: (1...7).contains) && day.contains(startMinute)
            && day.contains(endMinute)
    }

    private func previousWeekday(_ weekday: Int) -> Int {
        weekday == 1 ? 7 : weekday - 1
    }
}

extension WorkingHours: Codable {
    private enum CodingKeys: String, CodingKey {
        case isOn, startMinute, endMinute, weekdays
    }

    /// The weekdays are written in ascending order, so the same hours always write the same file.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isOn, forKey: .isOn)
        try container.encode(startMinute, forKey: .startMinute)
        try container.encode(endMinute, forKey: .endMinute)
        try container.encode(weekdays.sorted(), forKey: .weekdays)
    }
}

/// The weekdays in the order `calendar` shows a week, starting at its first weekday.
public func weekdaysInDisplayOrder(calendar: Calendar) -> [Int] {
    (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
}
