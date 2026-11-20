import Foundation

extension Date {
    /// This date with any fraction of a second dropped. Every stored time passes through it, so a
    /// value read back from `state.json` equals the value that was written.
    public var wholeSeconds: Date {
        Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down))
    }
}

/// What kind of sign-in a `Login` is, and the name the CLI needs to run it.
public enum LoginKind: Hashable, Sendable {
    case awsSSOSession(name: String)
    case databricksProfile(name: String, accountLevel: Bool)
    /// `command` is plain text in the state file, so it must not hold a secret.
    case custom(command: String?)
}

extension LoginKind: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, name, accountLevel, command
    }

    private enum TypeTag: String, Codable {
        case awsSSOSession, databricksProfile, custom
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(TypeTag.self, forKey: .type) {
        case .awsSSOSession:
            self = .awsSSOSession(name: try container.decode(String.self, forKey: .name))
        case .databricksProfile:
            self = .databricksProfile(
                name: try container.decode(String.self, forKey: .name),
                accountLevel: try container.decode(Bool.self, forKey: .accountLevel))
        case .custom:
            self = .custom(command: try container.decodeIfPresent(String.self, forKey: .command))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .awsSSOSession(let name):
            try container.encode(TypeTag.awsSSOSession, forKey: .type)
            try container.encode(name, forKey: .name)
        case .databricksProfile(let name, let accountLevel):
            try container.encode(TypeTag.databricksProfile, forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(accountLevel, forKey: .accountLevel)
        case .custom(let command):
            try container.encode(TypeTag.custom, forKey: .type)
            try container.encodeIfPresent(command, forKey: .command)
        }
    }
}

/// What the app last saw of an AWS session's cache file. It holds no token and no hash, so a login
/// done while the app wasn't running can be found at launch.
public struct AWSCacheRecord: Codable, Hashable, Sendable {
    public let modified: Date
    public let expiresAt: Date

    public init(modified: Date, expiresAt: Date) {
        self.modified = modified.wholeSeconds
        self.expiresAt = expiresAt.wholeSeconds
    }
}

/// What one Databricks check found. A skipped check has no result.
public enum DatabricksCheckResult: String, Codable, Hashable, Sendable {
    case valid
    /// The CLI's no-credentials error.
    case invalid
    /// The check failed for another reason, such as being offline.
    case couldntCheck
}

/// A Databricks login's last check that wasn't skipped: when, and what it found.
public struct DatabricksCheckRecord: Codable, Hashable, Sendable {
    public let at: Date
    public let result: DatabricksCheckResult

    /// `at` is rounded down to whole seconds.
    public init(at: Date, result: DatabricksCheckResult) {
        self.at = at.wholeSeconds
        self.result = result
    }
}

/// Why a login was invalidated.
public enum InvalidationReason: String, Codable, Hashable, Sendable {
    /// Its AWS cache file disappeared, as `aws sso logout` does.
    case loggedOut
    /// A Databricks check found it invalid.
    case foundInvalid
}

public struct Login: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var displayName: String
    public var kind: LoginKind
    /// Whole seconds; `nil` until known (a Databricks login has no default).
    public var sessionLength: TimeInterval?
    public var loginTime: Date?
    /// Set when the AWS cache file disappears or a Databricks check says invalid. The login counts
    /// as expired while `loginTime` is `nil` or not newer.
    public var invalidatedAt: Date?
    /// Why `invalidatedAt` was set. `nil` in a file written before the reason was stored, which
    /// `isLoggedOut` reads by the kind's only earlier cause.
    public var invalidationReason: InvalidationReason?
    /// The expiry the last notification was for, so a relaunch doesn't notify twice. A new login or
    /// a longer session changes the expiry and so re-arms the notification.
    public var notifiedForExpiry: Date?
    public var lastAWSCache: AWSCacheRecord?
    public var lastDatabricksCheck: DatabricksCheckRecord?
    /// The last check that answered, valid or invalid; a couldn't-check result leaves it as it was.
    /// Still valid is read from it.
    public var lastDatabricksAnswer: DatabricksCheckRecord?

    /// Dates and `sessionLength` are rounded down to whole seconds.
    public init(
        id: UUID = UUID(),
        displayName: String,
        kind: LoginKind,
        sessionLength: TimeInterval? = nil,
        loginTime: Date? = nil,
        invalidatedAt: Date? = nil,
        invalidationReason: InvalidationReason? = nil,
        notifiedForExpiry: Date? = nil,
        lastAWSCache: AWSCacheRecord? = nil,
        lastDatabricksCheck: DatabricksCheckRecord? = nil,
        lastDatabricksAnswer: DatabricksCheckRecord? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.sessionLength = sessionLength.map { $0.rounded(.down) }
        self.loginTime = loginTime?.wholeSeconds
        self.invalidatedAt = invalidatedAt?.wholeSeconds
        self.invalidationReason = invalidationReason
        self.notifiedForExpiry = notifiedForExpiry?.wholeSeconds
        self.lastAWSCache = lastAWSCache
        self.lastDatabricksCheck = lastDatabricksCheck
        self.lastDatabricksAnswer = lastDatabricksAnswer
    }

    /// 8 hours for AWS; `nil` for every other kind, where the user sets it.
    public static func defaultSessionLength(for kind: LoginKind) -> TimeInterval? {
        switch kind {
        case .awsSSOSession: 8 * 3600
        case .databricksProfile, .custom: nil
        }
    }

    /// The same login with every stored time and length rounded down to whole seconds.
    func roundedToWholeSeconds() -> Login {
        Login(
            id: id, displayName: displayName, kind: kind, sessionLength: sessionLength,
            loginTime: loginTime, invalidatedAt: invalidatedAt, invalidationReason: invalidationReason,
            notifiedForExpiry: notifiedForExpiry,
            lastAWSCache: lastAWSCache.map { AWSCacheRecord(modified: $0.modified, expiresAt: $0.expiresAt) },
            lastDatabricksCheck: lastDatabricksCheck.map { DatabricksCheckRecord(at: $0.at, result: $0.result) },
            lastDatabricksAnswer: lastDatabricksAnswer.map { DatabricksCheckRecord(at: $0.at, result: $0.result) })
    }
}

public struct Preset: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var loginIDs: [UUID]

    public init(id: UUID = UUID(), name: String, loginIDs: [UUID]) {
        self.id = id
        self.name = name
        self.loginIDs = loginIDs
    }
}

public struct Settings: Codable, Equatable, Sendable {
    public static let defaultNotificationLeadTime: TimeInterval = 30 * 60
    public static let defaultLoginTimeout: TimeInterval = 5 * 60

    /// Seconds before expiry at which a login counts as expiring.
    public var notificationLeadTime: TimeInterval
    /// Seconds a login may wait on the user before it is ended, as stored; logins run with
    /// `appliedLoginTimeout`.
    public var loginTimeout: TimeInterval

    /// The login timeouts a login runs with: from the shortest the pop-up lists to a day, which
    /// covers any time Settings has stored.
    public static let loginTimeoutRange: ClosedRange<TimeInterval> = 2 * 60...24 * 60 * 60

    /// The timeout a login runs with: `loginTimeout` held within `loginTimeoutRange`, or the
    /// default when it isn't a finite number. The stored value is left as it is.
    public var appliedLoginTimeout: TimeInterval {
        guard loginTimeout.isFinite else { return Settings.defaultLoginTimeout }
        return min(max(loginTimeout, Settings.loginTimeoutRange.lowerBound), Settings.loginTimeoutRange.upperBound)
    }

    public init(
        notificationLeadTime: TimeInterval = Settings.defaultNotificationLeadTime,
        loginTimeout: TimeInterval = Settings.defaultLoginTimeout
    ) {
        self.notificationLeadTime = notificationLeadTime
        self.loginTimeout = loginTimeout
    }
}

public struct AppState: Codable, Equatable, Sendable {
    /// The file-format version this build reads and writes.
    public static let currentVersion = 2

    public var version = AppState.currentVersion
    public var logins: [Login]
    public var presets: [Preset]
    public var settings: Settings

    public init(logins: [Login] = [], presets: [Preset] = [], settings: Settings = Settings()) {
        self.logins = logins
        self.presets = presets
        self.settings = settings
    }

    /// The same state with every stored time and session length rounded down to whole seconds.
    func roundedToWholeSeconds() -> AppState {
        var state = self
        state.logins = logins.map { $0.roundedToWholeSeconds() }
        return state
    }
}
