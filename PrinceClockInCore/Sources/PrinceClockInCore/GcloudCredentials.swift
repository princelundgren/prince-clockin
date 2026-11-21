import Foundation
import SQLite3

/// What the app saw of gcloud's credential store, `credentials.db` in the gcloud config directory:
/// each account's `rowid`, and when the file last changed. It holds no credential.
public struct GcloudCredentials: Equatable, Sendable {
    /// `account_id` to `rowid`, for every row.
    public let rowIDs: [String: Int64]
    /// The file's modification date, whole seconds; `nil` when there is no file.
    public let modified: Date?

    /// No file, so no accounts.
    public static let none = GcloudCredentials(rowIDs: [:], modified: nil)

    public init(rowIDs: [String: Int64], modified: Date?) {
        self.rowIDs = rowIDs
        self.modified = modified?.wholeSeconds
    }

    /// The account's row as seen now: present with its `rowid`, or missing.
    public func state(account: String) -> GcloudRowState {
        rowIDs[account].map(GcloudRowState.present) ?? .missing
    }
}

/// `credentials.db` in `configDirectory`.
public func gcloudCredentialsFile(configDirectory: URL) -> URL {
    configDirectory.appending(path: "credentials.db", directoryHint: .notDirectory)
}

/// The files a write to `credentials.db` changes: the store and SQLite's journal beside it. A watch
/// of the gcloud config directory reacts to these only, since every gcloud command writes its logs
/// and `access_tokens.db` there too.
public let gcloudCredentialsFileNames: Set<String> = ["credentials.db", "credentials.db-journal", "credentials.db-wal"]

/// A credential store that exists but could not be opened or queried. It names only the file.
public struct GcloudCredentialsError: Error, Equatable, LocalizedError {
    public let fileName: String

    public init(fileName: String) {
        self.fileName = fileName
    }

    public var errorDescription: String? { "Could not read gcloud's credential store \(fileName)." }
}

/// Reads the `account_id` and `rowid` of every row of the store at `url`, opened read-only. The
/// `value` column, which holds the refresh token, is never read. A missing file gives `.none`.
public func readGcloudCredentials(at url: URL) throws(GcloudCredentialsError) -> GcloudCredentials {
    let failure = GcloudCredentialsError(fileName: url.lastPathComponent)
    let manager = FileManager.default
    guard manager.fileExists(atPath: url.path) else { return .none }
    guard let modified = (try? manager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else {
        throw failure
    }
    var database: OpaquePointer?
    defer { sqlite3_close(database) }
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw failure }
    // Waits out a gcloud write in progress instead of failing at once with SQLITE_BUSY.
    sqlite3_busy_timeout(database, 200)
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(database, "SELECT account_id, rowid FROM credentials", -1, &statement, nil) == SQLITE_OK
    else { throw failure }
    var rowIDs: [String: Int64] = [:]
    while true {
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            guard let text = sqlite3_column_text(statement, 0) else { continue }
            rowIDs[String(cString: text)] = sqlite3_column_int64(statement, 1)
        case SQLITE_DONE:
            return GcloudCredentials(rowIDs: rowIDs, modified: modified)
        default:
            throw failure
        }
    }
}

/// The user accounts in `credentials`, in the order they last logged in (oldest first). Service
/// accounts, whose email ends in `.gserviceaccount.com`, are left out.
public func discoverGcloudAccounts(_ credentials: GcloudCredentials) -> [String] {
    credentials.rowIDs
        .filter { !gcloudAccountEmail($0.key).hasSuffix(".gserviceaccount.com") }
        .sorted { $0.value < $1.value }
        .map(\.key)
}

/// The email of a store `account_id`: the part before `#`, which names a universe domain.
public func gcloudAccountEmail(_ account: String) -> String {
    String(account.prefix { $0 != "#" })
}

/// One gcloud account's row in the store, as read and as stored per login.
public enum GcloudRowState: Codable, Hashable, Sendable {
    case missing
    case present(rowID: Int64)
}

/// What a read of gcloud's credential store, or of the Azure CLI's profile, means for one login.
public enum GcloudObservation: Equatable, Sendable {
    case noChange
    case newLogin(at: Date)
    case loggedOut
}

/// What a change from `previous`, `nil` when never seen, to `current` means, for a store last
/// modified at `modified`.
/// gcloud writes an account's row with `REPLACE INTO` at each login, which gives it a `rowid` larger
/// than any before; a token refresh doesn't touch the store. So a larger `rowid` is a login, at
/// `modified`, the best the app knows; a row gone is a logout (`gcloud auth revoke`); a first sight
/// is a baseline.
public func observe(
    previous: GcloudRowState?, current: GcloudRowState, modified: Date
) -> GcloudObservation {
    switch (previous, current) {
    case (nil, _), (.missing, .missing):
        .noChange
    case (.present, .missing):
        .loggedOut
    case (.missing, .present):
        .newLogin(at: modified)
    case (.present(let old), .present(let new)):
        new > old ? .newLogin(at: modified) : .noChange
    }
}
