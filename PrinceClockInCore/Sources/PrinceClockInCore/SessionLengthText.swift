import Foundation

/// Why the session length field doesn't store what was typed in it.
public enum SessionLengthRefusal: Error, Equatable, Sendable {
    /// Not a positive number of hours in the locale's number format.
    case notANumberOfHours
    /// Longer than `maximumSessionLength`.
    case tooLong

    public var message: String {
        switch self {
        case .notANumberOfHours: "Enter a number of hours"
        case .tooLong: TimerError.sessionLengthTooLong.message
        }
    }
}

/// What the session length field stores for `text`, a number of hours in `locale`'s format:
/// `nil` for empty text, which makes the session length unknown, else the length in seconds,
/// rounded down.
/// - Throws: `.notANumberOfHours` for text that isn't a positive, finite number of hours, or one
///   under a second; `.tooLong` for a length over `maximumSessionLength`.
public func sessionLength(fieldText text: String, locale: Locale) throws(SessionLengthRefusal) -> TimeInterval? {
    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    guard let length = sessionLengthFromHours(text, locale: locale) else { throw .notANumberOfHours }
    do throws(TimerError) {
        return try checkedSessionLength(length)
    } catch .sessionLengthNotPositive {
        throw .notANumberOfHours
    } catch {
        throw .tooLong
    }
}

/// `length` as a number of hours in `locale`'s format, as the session length field and Set
/// Timer's Custom… show it; empty when the length is unknown. Six fraction digits, so the text
/// reads back as the same whole seconds.
public func sessionLengthHoursText(_ length: TimeInterval?, locale: Locale) -> String {
    guard let length else { return "" }
    return (length / secondsPerHour).formatted(
        .number.grouping(.never).precision(.fractionLength(0...6)).locale(locale))
}

/// `text` as a finite number of hours in `locale`'s format, zero or less included, in seconds
/// rounded to the nearest, since a decimal number of hours such as a third is never exact; `nil`
/// otherwise.
func sessionLengthFromHours(_ text: String, locale: Locale) -> TimeInterval? {
    // A whole match, since parsing takes a leading number and ignores what follows it.
    let text = text.trimmingCharacters(in: .whitespaces)
    guard let hours = text.wholeMatch(of: FloatingPointFormatStyle<Double>(locale: locale))?.output,
          hours.isFinite
    else { return nil }
    return (hours * secondsPerHour).rounded()
}

private let secondsPerHour: TimeInterval = 3600
