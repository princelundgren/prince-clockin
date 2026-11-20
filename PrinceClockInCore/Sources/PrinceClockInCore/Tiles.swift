import Foundation

/// A house colour from the app's asset catalog; the raw value is the colour's name there. A token
/// has only the meanings the design's Colours table gives it.
public enum ColourToken: String, Sendable {
    case expired = "Expired"
    case expiring = "Expiring"
    case loggedIn = "LoggedIn"
    case running = "Running"
}

/// Whether a login is in the running batch.
public enum TileActivity: Equatable, Sendable {
    case idle
    case queued
    case running
}

/// What the coordinator knows of a login beyond its stored state, for its tile.
public struct TileFacts: Equatable, Sendable {
    public var activity: TileActivity
    /// Why its last run failed, until it runs again.
    public var failure: LoginFailure?
    /// A custom login held back until the user approves its command.
    public var isAwaitingApproval: Bool
    /// The time of an AWS cache rewrite that could be a login or a renewal.
    public var possibleLoginAt: Date?
    /// Whether the first check after the Mac woke found that rewrite.
    public var isPossibleLoginFoundOnWake: Bool

    public init(
        activity: TileActivity = .idle, failure: LoginFailure? = nil, isAwaitingApproval: Bool = false,
        possibleLoginAt: Date? = nil, isPossibleLoginFoundOnWake: Bool = false
    ) {
        self.activity = activity
        self.failure = failure
        self.isAwaitingApproval = isAwaitingApproval
        self.possibleLoginAt = possibleLoginAt
        self.isPossibleLoginFoundOnWake = isPossibleLoginFoundOnWake
    }
}

/// The state symbol at a tile's leading edge.
public enum TileSymbol: Equatable, Sendable {
    case systemImage(String)
    /// A small indeterminate progress indicator, for a login running or queued.
    case progress
}

/// The line under a tile's name.
public enum TileSubtitle: Equatable, Sendable {
    /// The login's kind, which gives way first when the line doesn't fit.
    case kind(String)
    /// The login's state and time, which is never cut off.
    case status(String)

    public var text: String {
        switch self {
        case .kind(let text), .status(let text): text
        }
    }
}

/// What a tile shows on its trailing side.
public enum TileTrailing: Equatable, Sendable {
    case timeLeft(String)
    case stateWord(String)
    /// Nothing, for a timer that is unknown.
    case empty
    /// A visible Log In, on a tile that logs in when clicked.
    case logIn
}

/// What a tile shows below its first line, for the user to answer.
public enum TileDetail: Equatable, Sendable {
    /// With Try Again and Show Output…, and Open System Settings… for System Settings → Privacy &
    /// Security → Automation when the failure is a denied permission to control Terminal.
    case failed(message: String, offersAutomationSettings: Bool = false)
    /// "Logged in elsewhere?", with the confirming button's title, Log In and Set Timer….
    case possibleLogin(question: String, confirmTitle: String)
    /// With Edit Session Length….
    case stillValid(message: String)
    /// The command, with Run It and Not Now.
    case notYetApproved(command: String)
    /// A Databricks login that logged in with no session length and hasn't been invalidated since,
    /// whether or not the user chose No timer: the prompt, with Set Timer's Session Length pop-up,
    /// whose length times the timer from that login.
    case needsSessionLength(prompt: String)
}

/// Everything a tile draws and says, decided from one login.
public struct TilePresentation: Equatable, Identifiable, Sendable {
    public let id: UUID
    /// The full display name; the view truncates it in the middle.
    public let name: String
    public let symbol: TileSymbol
    /// The symbol's colour and the tile's tint; `nil` for a state no token means.
    public let colour: ColourToken?
    public let subtitle: TileSubtitle
    public let trailing: TileTrailing
    /// What the trailing side shows while the pointer is on the tile: Log In when a click logs in.
    public let trailingOnHover: TileTrailing
    /// Whether clicking the tile logs in: whenever nothing is pending. A click does nothing while
    /// the tile is running, queued, failed, waiting for approval or asking.
    public let clickLogsIn: Bool
    public let detail: TileDetail?
    /// Whether the login is due: expiring or expired and not still valid.
    public let isDue: Bool
    /// "name, kind, state, time", with durations in the wide style; a pending item's word is the state.
    public let accessibilityLabel: String
    /// What activating the tile does; empty when it does nothing.
    public let accessibilityHint: String
}

/// The tile for `login` at `now`. Running or queued comes first, then a failure, a command not yet
/// approved and a possible login, in that order, then the timer. A tile with nothing pending logs
/// in when clicked, due or not.
public func tilePresentation(
    for login: Login, now: Date, leadTime: TimeInterval, facts: TileFacts, locale: Locale, calendar: Calendar
) -> TilePresentation {
    let timer = TileTimer(login, now: now, leadTime: leadTime)
    let pending = TilePending(facts, login: login)
    let due = isDue(login, now: now, leadTime: leadTime)
    let clickLogsIn = pending == nil
    let trailing: TileTrailing = clickLogsIn && due ? .logIn : pending?.trailing ?? timer.trailing(locale: locale)
    let kind = loginKindName(login.kind)
    let spokenParts = [
        login.displayName, kind, pending?.spokenWord ?? timer.spokenState, timer.spokenTime(locale: locale),
    ].compactMap { $0 }
    return TilePresentation(
        id: login.id,
        name: login.displayName,
        symbol: pending?.symbol ?? .systemImage(timer.symbolName),
        colour: pending.map(\.colour) ?? timer.colour,
        subtitle: timer.subtitle(kind: kind, locale: locale, calendar: calendar),
        trailing: trailing,
        trailingOnHover: clickLogsIn ? .logIn : trailing,
        clickLogsIn: clickLogsIn,
        detail: detail(pending: pending, timer: timer, login: login, now: now, locale: locale, calendar: calendar),
        isDue: due,
        accessibilityLabel: spokenParts.joined(separator: ", "),
        accessibilityHint: clickLogsIn ? "Logs in" : "")
}

/// A choice in the Session Length pop-up.
public enum SessionLengthChoice: Hashable, Sendable {
    case length(TimeInterval)
    /// Any other number of hours or days, typed in.
    case custom
    /// Leaves the session length unknown.
    case noTimer
}

/// One item of the Session Length pop-up.
public struct SessionLengthOption: Hashable, Sendable {
    public let choice: SessionLengthChoice
    public let title: String
}

/// The one list of session lengths, for Set Timer and Settings: 8 hours, 12 hours, 1 day, 3 days,
/// 7 days, Custom… and No timer.
public func sessionLengthOptions() -> [SessionLengthOption] {
    listedSessionLengths.map { SessionLengthOption(choice: .length($0), title: sessionLengthText($0)) } + [
        SessionLengthOption(choice: .custom, title: "Custom…"),
        SessionLengthOption(choice: .noTimer, title: "No timer"),
    ]
}

/// The choice a Session Length pop-up shows for a stored `length`: its own item when listed,
/// Custom… when not, and No timer when unknown.
public func sessionLengthChoice(for length: TimeInterval?) -> SessionLengthChoice {
    guard let length else { return .noTimer }
    return isListedSessionLength(length) ? .length(length) : .custom
}

private let listedSessionLengths: [TimeInterval] = [8, 12, 24, 72, 168].map { $0 * 3600 }

/// Whether `length` has its own item in `sessionLengthOptions()`, rather than Custom….
func isListedSessionLength(_ length: TimeInterval) -> Bool {
    listedSessionLengths.contains(length)
}

/// A session length as English copy, in whole days, else whole hours, else minutes ("8 hours",
/// "1 day").
public func sessionLengthText(_ length: TimeInterval) -> String {
    let (count, unit) = sessionLengthUnits(length)
    return "\(count) \(unit)\(count == 1 ? "" : "s")"
}

/// The session length before a noun ("1-day timer").
func sessionLengthAdjective(_ length: TimeInterval) -> String {
    let (count, unit) = sessionLengthUnits(length)
    return "\(count)-\(unit)"
}

private func sessionLengthUnits(_ length: TimeInterval) -> (count: Int, unit: String) {
    let minutes = Int(length / 60)
    if minutes > 0, minutes.isMultiple(of: 24 * 60) { return (minutes / (24 * 60), "day") }
    if minutes > 0, minutes.isMultiple(of: 60) { return (minutes / 60, "hour") }
    return (minutes, "minute")
}

/// The kind as the glossary names it ("AWS SSO session").
func loginKindName(_ kind: LoginKind) -> String {
    switch kind {
    case .awsSSOSession: "AWS SSO session"
    case .databricksProfile(_, accountLevel: false): "Databricks profile"
    case .databricksProfile(_, accountLevel: true): "Databricks account profile"
    case .custom: "Custom login"
    }
}

private func detail(
    pending: TilePending?, timer: TileTimer, login: Login, now: Date, locale: Locale, calendar: Calendar
) -> TileDetail? {
    switch pending {
    case .activity: return nil
    case .failure(let failure):
        return .failed(message: failure.message, offersAutomationSettings: failure == .terminalNotPermitted)
    case .approval(let command): return .notYetApproved(command: command)
    case .possibleLogin(let time, let isFoundOnWake):
        let when = calendar.isDate(time, inSameDayAs: now)
            ? "at \(clockTimeText(time, locale: locale, calendar: calendar))"
            : dayAndTimeText(time, locale: locale, calendar: calendar)
        let changed = isFoundOnWake ? "\(when), while this Mac slept" : when
        return .possibleLogin(
            question: "Its login changed \(changed). Was that you?", confirmTitle: "Mark as Logged In \(when)")
    case nil:
        if case .databricksProfile = login.kind, isLoggedInWithNoLength(login) {
            return .needsSessionLength(prompt: "Choose a session length")
        }
        guard case .stillValid = timer, let length = login.sessionLength else { return nil }
        return .stillValid(message: "Its \(sessionLengthAdjective(length)) timer ran out, but Databricks says the "
            + "login still works. The session length may be too short.")
    }
}

/// What a tile shows ahead of its timer, the first that applies.
private enum TilePending: Equatable {
    case activity(TileActivity)
    case failure(LoginFailure)
    case approval(command: String)
    case possibleLogin(at: Date, isFoundOnWake: Bool)

    init?(_ facts: TileFacts, login: Login) {
        if facts.activity != .idle {
            self = .activity(facts.activity)
        } else if let failure = facts.failure {
            self = .failure(failure)
        } else if facts.isAwaitingApproval, case .custom(let command?) = login.kind {
            self = .approval(command: command)
        } else if let time = facts.possibleLoginAt {
            self = .possibleLogin(at: time, isFoundOnWake: facts.isPossibleLoginFoundOnWake)
        } else {
            return nil
        }
    }

    var symbol: TileSymbol {
        switch self {
        case .activity: .progress
        case .failure: .systemImage("exclamationmark.triangle")
        case .approval: .systemImage("terminal")
        case .possibleLogin: .systemImage("questionmark.circle")
        }
    }

    var colour: ColourToken? {
        switch self {
        case .activity: .running
        case .failure: .expired
        case .approval, .possibleLogin: nil
        }
    }

    /// The state word trailing, or `nil` to show the timer's.
    var trailing: TileTrailing? {
        switch self {
        case .activity(.running): .stateWord("Logging in")
        case .activity: .stateWord("Queued")
        case .failure: .stateWord("Failed")
        case .approval: .stateWord("Not yet approved")
        case .possibleLogin: nil
        }
    }

    var spokenWord: String {
        switch self {
        case .activity(.running): "logging in"
        case .activity: "queued"
        case .failure: "failed"
        case .approval: "not yet approved"
        case .possibleLogin: "logged in elsewhere?"
        }
    }
}

/// A login's timer as its tile shows it.
private enum TileTimer {
    case ok(remaining: TimeInterval)
    case expiring(remaining: TimeInterval)
    /// `ago` is the time since it expired, or since it was found invalid if that came first.
    case expired(ago: TimeInterval)
    case loggedOut
    case stillValid(checkedAt: Date?)
    /// Logged in, with no session length to time it.
    case noExpiry
    case unknown

    init(_ login: Login, now: Date, leadTime: TimeInterval) {
        if isStillValid(login, now: now) {
            self = .stillValid(checkedAt: login.lastDatabricksAnswer?.at)
            return
        }
        if isLoggedInWithNoExpiry(login) {
            self = .noExpiry
            return
        }
        switch timerState(for: login, now: now, leadTime: leadTime) {
        case .ok(let remaining): self = .ok(remaining: remaining)
        case .expiring(let remaining): self = .expiring(remaining: remaining)
        case .expired where isLoggedOut(login): self = .loggedOut
        case .expired: self = .expired(ago: now.timeIntervalSince(expiredAt(login) ?? now))
        case .unknown: self = .unknown
        }
    }

    var symbolName: String {
        switch self {
        case .ok, .noExpiry: "checkmark.circle"
        case .expiring: "clock"
        case .expired, .loggedOut: "xmark.circle"
        case .stillValid: "clock.badge.checkmark"
        case .unknown: "timer"
        }
    }

    var colour: ColourToken? {
        switch self {
        case .ok, .stillValid, .noExpiry: .loggedIn
        case .expiring: .expiring
        case .expired, .loggedOut: .expired
        case .unknown: nil
        }
    }

    func subtitle(kind: String, locale: Locale, calendar: Calendar) -> TileSubtitle {
        switch self {
        case .expiring(let remaining):
            .status("Expiring · \(timeLeftText(remaining, locale: locale)) left")
        case .expired(let ago):
            .status("Expired \(agoText(ago, locale: locale)) ago")
        case .loggedOut:
            .status("Logged out")
        case .stillValid(let checkedAt?):
            .status("Checked \(clockTimeText(checkedAt, locale: locale, calendar: calendar)) · valid")
        case .ok, .stillValid(nil), .noExpiry, .unknown:
            .kind(kind)
        }
    }

    func trailing(locale: Locale) -> TileTrailing {
        switch self {
        case .ok(let remaining), .expiring(let remaining): .timeLeft(timeLeftText(remaining, locale: locale))
        case .expired: .stateWord("Expired")
        case .loggedOut: .stateWord("Logged out")
        case .stillValid: .stateWord("Still valid")
        case .noExpiry: .stateWord("Logged in")
        case .unknown: .empty
        }
    }

    /// The state VoiceOver reads, or `nil` for a timer it reads only as "No timer".
    var spokenState: String? {
        switch self {
        case .ok, .noExpiry: "logged in"
        case .expiring: "expiring"
        case .expired: "expired"
        case .loggedOut: "logged out"
        case .stillValid: "still valid"
        case .unknown: nil
        }
    }

    /// The time VoiceOver reads, or `nil` for a state with none.
    func spokenTime(locale: Locale) -> String? {
        switch self {
        case .ok(let remaining), .expiring(let remaining): "\(spokenTimeLeftText(remaining, locale: locale)) left"
        case .expired(let ago): "\(spokenAgoText(ago, locale: locale)) ago"
        case .loggedOut, .stillValid, .noExpiry: nil
        case .unknown: "No timer"
        }
    }
}

/// How long ago, in the time-left format; under a minute, including none, "<1m".
private func agoText(_ elapsed: TimeInterval, locale: Locale) -> String {
    elapsed < 60 ? "<1m" : timeLeftText(elapsed, locale: locale)
}

private func spokenAgoText(_ elapsed: TimeInterval, locale: Locale) -> String {
    elapsed < 60 ? "less than a minute" : spokenTimeLeftText(elapsed, locale: locale)
}
