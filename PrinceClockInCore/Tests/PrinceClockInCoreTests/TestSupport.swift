import Foundation
import PrinceClockInCore

/// Parses an ISO 8601 fixture such as `2026-11-17T09:00:00Z`; a malformed fixture fails the test run.
func at(_ iso: String) -> Date {
    guard let date = try? Date(iso, strategy: .iso8601) else {
        preconditionFailure("bad fixture date \(iso)")
    }
    return date
}
