import Foundation

public enum LoadResult: Equatable, Sendable {
    case loaded(AppState)
    case empty
    /// The file was unreadable or of a version this build can't read, and now lives at `backup`.
    case setAside(backup: URL)
}

/// Reads and writes `state.json` in one directory. A file it can't use is renamed, never overwritten.
public final class StateStore: Sendable {

    private let directory: URL
    private var fileURL: URL { directory.appending(path: "state.json", directoryHint: .notDirectory) }

    public init(directory: URL) {
        self.directory = directory
    }

    /// A missing file gives `.empty`. A version-1 file loads as the current version, and the file
    /// stays as it is until the next `save`. A file that won't decode, or whose version is neither 1
    /// nor `AppState.currentVersion`, is renamed to `state-YYYYMMDD-HHMMSS-<4 hex>.json.bak` and
    /// gives `.setAside`. Every date and session length is rounded down to whole seconds.
    ///
    /// If the rename itself fails, the directory isn't writable and `save` would fail the same way,
    /// so the result is `.empty`.
    public func load() -> LoadResult {
        guard let data = try? Data(contentsOf: fileURL) else {
            return FileManager.default.fileExists(atPath: fileURL.path) ? setAside() : .empty
        }
        struct Header: Decodable { let version: Int }
        guard let header = try? Self.makeDecoder().decode(Header.self, from: data),
              let current = Self.inCurrentFormat(data, version: header.version),
              let state = try? Self.makeDecoder().decode(AppState.self, from: current)
        else { return setAside() }
        return .loaded(state.roundedToWholeSeconds())
    }

    /// `data`, a file of format `version`, in the current format; `nil` for a version this build
    /// can't read.
    private static func inCurrentFormat(_ data: Data, version: Int) -> Data? {
        switch version {
        case AppState.currentVersion: data
        case 1: upgradedFromVersion1(data)
        default: nil
        }
    }

    /// Version 1 differs from version 2 only in two key names: a login's `warnedForExpiry` and the
    /// settings' `warningLeadTime`.
    private static func upgradedFromVersion1(_ data: Data) -> Data? {
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if var settings = root["settings"] as? [String: Any] {
            settings["notificationLeadTime"] = settings.removeValue(forKey: "warningLeadTime")
            root["settings"] = settings
        }
        if let logins = root["logins"] as? [[String: Any]] {
            root["logins"] = logins.map { login in
                var login = login
                login["notifiedForExpiry"] = login.removeValue(forKey: "warnedForExpiry")
                return login
            }
        }
        root["version"] = AppState.currentVersion
        return try? JSONSerialization.data(withJSONObject: root)
    }

    /// Writes atomically, creating the directory if needed. Times and session lengths are rounded
    /// down to whole seconds first, so what is stored is what `load` returns.
    public func save(_ state: AppState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.makeEncoder().encode(state.roundedToWholeSeconds())
        try data.write(to: fileURL, options: .atomic)
    }

    private func setAside() -> LoadResult {
        let manager = FileManager.default
        let stamp = Date.now.formatted(
            Date.VerbatimFormatStyle(
                format: "\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
                timeZone: .current, calendar: Calendar(identifier: .gregorian)))
        var backup: URL
        repeat {
            let suffix = String(format: "%04x", UInt16.random(in: .min ... .max))
            backup = directory.appending(path: "state-\(stamp)-\(suffix).json.bak", directoryHint: .notDirectory)
        } while manager.fileExists(atPath: backup.path)
        do {
            try manager.moveItem(at: fileURL, to: backup)
            return .setAside(backup: backup)
        } catch {
            return .empty
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
