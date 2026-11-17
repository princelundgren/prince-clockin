import CryptoKit
import Foundation

/// What the app saw of one session's cache file. `refreshTokenHash` is the SHA-256 digest of the
/// file's `refreshToken`, kept in memory only; it is `nil` after a relaunch until the file is read
/// once, or when the file has no token.
public struct AWSCacheSnapshot: Equatable, Sendable {
    public let modified: Date
    public let expiresAt: Date
    public let refreshTokenHash: Data?

    public init(modified: Date, expiresAt: Date, refreshTokenHash: Data? = nil) {
        self.modified = modified.wholeSeconds
        self.expiresAt = expiresAt.wholeSeconds
        self.refreshTokenHash = refreshTokenHash
    }
}

/// What the app last saw for one session.
public enum AWSCacheState: Equatable, Sendable {
    case unread
    case missing
    case present(AWSCacheSnapshot)
}

public enum AWSCacheObservation: Equatable, Sendable {
    case noChange
    case newLogin(at: Date)
    /// A rewrite the file alone can't tell from a renewal; the app asks the user.
    case possibleLogin(at: Date)
    case renewed
    case loggedOut
}

/// A cache file that could not be read or decoded. It carries only the file's name: a decoding
/// error's context can echo the file's contents, so it is never wrapped.
public struct AWSCacheError: Error, Equatable, LocalizedError {
    public let fileName: String

    public init(fileName: String) {
        self.fileName = fileName
    }

    public var errorDescription: String? { "Could not read the AWS cache file \(fileName)." }
}

/// The session's cache file in `cacheDirectory`: the SHA-1 hex of the session name plus `.json`,
/// which is the name botocore's cache key gives a login that has an `sso-session`. SHA-1 names a
/// file here and protects nothing.
public func awsCacheFile(forSession name: String, cacheDirectory: URL) -> URL {
    let digest = Insecure.SHA1.hash(data: Data(name.utf8))
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return cacheDirectory.appending(path: "\(hex).json", directoryHint: .notDirectory)
}

/// Reads the cache file at `url`. A missing file gives `.missing`. A file whose modification date
/// equals `previous`'s, and whose hash is known, gives `previous` without being read. Otherwise only
/// `expiresAt` and `refreshToken` are decoded, and the token is hashed at once and dropped.
public func readCacheState(at url: URL, previous: AWSCacheState) throws -> AWSCacheState {
    let manager = FileManager.default
    guard manager.fileExists(atPath: url.path) else { return .missing }
    let failure = AWSCacheError(fileName: url.lastPathComponent)
    guard let attributes = try? manager.attributesOfItem(atPath: url.path),
        let modified = (attributes[.modificationDate] as? Date)?.wholeSeconds
    else { throw failure }
    if case .present(let known) = previous, known.modified == modified, known.refreshTokenHash != nil {
        return previous
    }
    struct CacheFile: Decodable {
        let expiresAt: Date
        let refreshToken: String?
    }
    do {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(CacheFile.self, from: Data(contentsOf: url))
        let hash = file.refreshToken.map { Data(SHA256.hash(data: Data($0.utf8))) }
        return .present(AWSCacheSnapshot(modified: modified, expiresAt: file.expiresAt, refreshTokenHash: hash))
    } catch {
        throw failure
    }
}

/// The CLI renews a token only inside this window before its `expiresAt`.
private let renewalWindow: TimeInterval = 15 * 60

/// What a change from `previous` to `current` means for the session's timer. `timerExpiry` is when
/// the timer says the session ends, or `nil` while it is unknown.
public func observe(
    previous: AWSCacheState, current: AWSCacheState, timerExpiry: Date?, leadTime: TimeInterval
) -> AWSCacheObservation {
    switch (previous, current) {
    case (_, .unread), (.unread, _), (.missing, .missing):
        return .noChange
    case (.present, .missing):
        return .loggedOut
    case (.missing, .present(let snapshot)):
        return .newLogin(at: snapshot.modified)
    case (.present(let old), .present(let new)):
        guard new.modified > old.modified else { return .noChange }
        if let oldHash = old.refreshTokenHash, let newHash = new.refreshTokenHash {
            return oldHash == newHash ? .renewed : .newLogin(at: new.modified)
        }
        if old.expiresAt.timeIntervalSince(new.modified) > renewalWindow {
            return .newLogin(at: new.modified)
        }
        guard let timerExpiry else { return .possibleLogin(at: new.modified) }
        if new.modified >= timerExpiry { return .newLogin(at: new.modified) }
        if new.modified >= timerExpiry.addingTimeInterval(-leadTime) {
            return .possibleLogin(at: new.modified)
        }
        return .renewed
    }
}
