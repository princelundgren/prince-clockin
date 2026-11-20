import Foundation

public enum LoadResult: Equatable, Sendable {
    case loaded(AppState)
    case empty
    /// The file was unreadable or from another version and now lives at `backup`.
    case setAside(backup: URL)
}

/// Reads and writes `state.json` in one directory. A file it can't use is renamed, never overwritten.
public final class StateStore: Sendable {

    private let directory: URL
    private var fileURL: URL { directory.appending(path: "state.json", directoryHint: .notDirectory) }

    public init(directory: URL) {
        self.directory = directory
    }

    /// A missing file gives `.empty`. A file that won't decode, or whose version isn't
    /// `AppState.currentVersion`, is renamed to `state-YYYYMMDD-HHMMSS-<4 hex>.json.bak` and gives
    /// `.setAside`. Every date and session length is rounded down to whole seconds.
    ///
    /// If the rename itself fails, the directory isn't writable and `save` would fail the same way,
    /// so the result is `.empty`.
    public func load() -> LoadResult {
        guard let data = try? Data(contentsOf: fileURL) else {
            return FileManager.default.fileExists(atPath: fileURL.path) ? setAside() : .empty
        }
        struct Header: Decodable { let version: Int }
        guard let header = try? Self.makeDecoder().decode(Header.self, from: data),
              header.version == AppState.currentVersion,
              let state = try? Self.makeDecoder().decode(AppState.self, from: data)
        else { return setAside() }
        return .loaded(state.roundedToWholeSeconds())
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
