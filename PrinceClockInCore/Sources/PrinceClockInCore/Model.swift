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
    /// The expiry the last warning was for, so a relaunch doesn't warn twice. A new login or a
    /// longer session changes the expiry and so re-arms the warning.
    public var warnedForExpiry: Date?
    public var lastAWSCache: AWSCacheRecord?

    /// Dates and `sessionLength` are rounded down to whole seconds.
    public init(
        id: UUID = UUID(),
        displayName: String,
        kind: LoginKind,
        sessionLength: TimeInterval? = nil,
        loginTime: Date? = nil,
        invalidatedAt: Date? = nil,
        warnedForExpiry: Date? = nil,
        lastAWSCache: AWSCacheRecord? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.sessionLength = sessionLength.map { $0.rounded(.down) }
        self.loginTime = loginTime?.wholeSeconds
        self.invalidatedAt = invalidatedAt?.wholeSeconds
        self.warnedForExpiry = warnedForExpiry?.wholeSeconds
        self.lastAWSCache = lastAWSCache
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
            loginTime: loginTime, invalidatedAt: invalidatedAt, warnedForExpiry: warnedForExpiry,
            lastAWSCache: lastAWSCache.map { AWSCacheRecord(modified: $0.modified, expiresAt: $0.expiresAt) })
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
    public static let defaultWarningLeadTime: TimeInterval = 30 * 60
    public static let defaultLoginTimeout: TimeInterval = 5 * 60

    /// Seconds before expiry at which a login counts as expiring.
    public var warningLeadTime: TimeInterval
    /// Seconds a login may wait on the user before it is ended.
    public var loginTimeout: TimeInterval

    public init(
        warningLeadTime: TimeInterval = Settings.defaultWarningLeadTime,
        loginTimeout: TimeInterval = Settings.defaultLoginTimeout
    ) {
        self.warningLeadTime = warningLeadTime
        self.loginTimeout = loginTimeout
    }
}

public struct AppState: Codable, Equatable, Sendable {
    /// The file-format version this build reads and writes.
    public static let currentVersion = 1

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
