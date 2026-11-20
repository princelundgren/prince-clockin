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

/// What a tile shows on its trailing side, before its "…".
public enum TileTrailing: Equatable, Sendable {
    case timeLeft(String)
    case stateWord(String)
    /// A visible Log In, on a tile that logs in when clicked.
    case logIn
}

/// Which control a tile is.
public enum TileControl: Equatable, Sendable {
    /// The whole tile is a menu of its actions.
    case actionsMenu
    /// The tile is a button that logs in, beside a "…" menu of its actions.
    case logInButton
}

/// What a tile shows below its first line, for the user to answer.
public enum TileDetail: Equatable, Sendable {
    /// With Try Again and Show Output…, and Open System Settings… for System Settings → Privacy &
    /// Security → Automation when the failure is a denied permission to control Terminal.
    case failed(message: String, offersAutomationSettings: Bool = false)
    /// "Logged in elsewhere?", with the confirming button's title and Set Timer….
    case possibleLogin(question: String, confirmTitle: String)
    /// With Edit Session Length….
    case stillValid(message: String)
    /// The command, with Run It and Not Now.
    case notYetApproved(command: String)
}

/// One item of a tile's "…" menu, which is also its context menu and its accessibility actions.
public enum TileMenuItem: Hashable, Sendable {
    case logIn
    case setTimer
    /// Opens Set Timer instead while the session length is unknown, to ask for it.
    case markLoggedInNow(opensSetTimer: Bool)
    /// A submenu of `sessionLengthOptions(current:)`.
    case sessionLength
    case editInSettings
    case cancelAll

    /// The item's title, in the glossary's title case.
    public var title: String {
        switch self {
        case .logIn: "Log In"
        case .setTimer: "Set Timer…"
        case .markLoggedInNow: "Mark as Logged In Now"
        case .sessionLength: "Session Length"
        case .editInSettings: "Edit in Settings…"
        case .cancelAll: "Cancel All"
        }
    }
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
    public let control: TileControl
    /// Whether clicking a `.logInButton` logs in: only while the tile is due and nothing is pending.
    /// A held button does nothing once the tile is no longer due, or is running, queued, failed,
    /// waiting for approval or asking.
    public let clickLogsIn: Bool
    public let detail: TileDetail?
    /// Whether the login is due: expiring or expired and not still valid.
    public let isDue: Bool
    public let menuItems: [TileMenuItem]
    /// "name, kind, state, time", with durations in the wide style; a pending item's word is the state.
    public let accessibilityLabel: String
    /// What activating the tile does; empty when it does nothing.
    public let accessibilityHint: String
    /// The "…" menu's label for VoiceOver.
    public let actionsLabel: String
}

/// The tile for `login` at `now`. Running or queued comes first, then a failure, a command not yet
/// approved and a possible login, in that order, then the timer. A due tile with nothing pending
/// logs in when clicked; every other tile opens its actions. `heldControl`, the control the tile
/// was when the pointer entered it, keeps the click's action while the pointer stays.
public func tilePresentation(
    for login: Login, now: Date, leadTime: TimeInterval, facts: TileFacts, holding heldControl: TileControl? = nil,
    locale: Locale, calendar: Calendar
) -> TilePresentation {
    let timer = TileTimer(login, now: now, leadTime: leadTime)
    let pending = TilePending(facts, login: login)
    let due = isDue(login, now: now, leadTime: leadTime)
    let control = heldControl ?? (due && pending == nil ? .logInButton : .actionsMenu)
    let clickLogsIn = control == .logInButton && due && pending == nil
    let kind = loginKindName(login.kind)
    var menuItems: [TileMenuItem] = [
        .logIn, .setTimer, .markLoggedInNow(opensSetTimer: login.sessionLength == nil), .sessionLength,
        .editInSettings,
    ]
    if case .activity = pending { menuItems.append(.cancelAll) }
    let spokenParts = [
        login.displayName, kind, pending?.spokenWord ?? timer.spokenState, timer.spokenTime(locale: locale),
    ].compactMap { $0 }
    return TilePresentation(
        id: login.id,
        name: login.displayName,
        symbol: pending?.symbol ?? .systemImage(timer.symbolName),
        colour: pending.map(\.colour) ?? timer.colour,
        subtitle: timer.subtitle(kind: kind, locale: locale, calendar: calendar),
        trailing: clickLogsIn ? .logIn : pending?.trailing ?? timer.trailing(locale: locale),
        control: control,
        clickLogsIn: clickLogsIn,
        detail: detail(pending: pending, timer: timer, login: login, now: now, locale: locale, calendar: calendar),
        isDue: due,
        menuItems: menuItems,
        accessibilityLabel: spokenParts.joined(separator: ", "),
        accessibilityHint: clickLogsIn ? "Logs in" : control == .actionsMenu ? "Shows actions" : "",
        actionsLabel: "Actions for \(login.displayName)")
}

/// A choice in the Session Length submenu.
public enum SessionLengthChoice: Hashable, Sendable {
    case length(TimeInterval)
    /// Any other number of hours or days, typed in.
    case custom
    /// Leaves the session length unknown.
    case noTimer
}

/// One item of the Session Length submenu, checked when it is the login's length.
public struct SessionLengthOption: Hashable, Sendable {
    public let choice: SessionLengthChoice
    public let title: String
    public let isSelected: Bool
}

/// The one list of session lengths, for the panel's Session Length submenu, Set Timer and
/// Settings: 8 hours, 12 hours, 1 day, 3 days, 7 days, Custom… and No timer. Custom… is checked
/// for a length not listed.
public func sessionLengthOptions(current: TimeInterval?) -> [SessionLengthOption] {
    let listed = listedSessionLengths.map {
        SessionLengthOption(choice: .length($0), title: sessionLengthText($0), isSelected: current == $0)
    }
    let isCustom = current.map { !isListedSessionLength($0) } ?? false
    return listed + [
        SessionLengthOption(choice: .custom, title: "Custom…", isSelected: isCustom),
        SessionLengthOption(choice: .noTimer, title: "No timer", isSelected: current == nil),
    ]
}

/// The choice a Session Length pop-up shows for a stored `length`: its own item when listed,
/// Custom… when not, and No timer when unknown, as `sessionLengthOptions(current:)` checks them.
public func sessionLengthChoice(for length: TimeInterval?) -> SessionLengthChoice {
    guard let length else { return .noTimer }
    return isListedSessionLength(length) ? .length(length) : .custom
}

private let listedSessionLengths: [TimeInterval] = [8, 12, 24, 72, 168].map { $0 * 3600 }

/// Whether `length` has its own item in `sessionLengthOptions(current:)`, rather than Custom….
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
    case unknown

    init(_ login: Login, now: Date, leadTime: TimeInterval) {
        if isStillValid(login, now: now) {
            self = .stillValid(checkedAt: login.lastDatabricksAnswer?.at)
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
        case .ok: "checkmark.circle"
        case .expiring: "clock"
        case .expired, .loggedOut: "xmark.circle"
        case .stillValid: "clock.badge.checkmark"
        case .unknown: "timer"
        }
    }

    var colour: ColourToken? {
        switch self {
        case .ok, .stillValid: .loggedIn
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
        case .ok, .stillValid(nil), .unknown:
            .kind(kind)
        }
    }

    func trailing(locale: Locale) -> TileTrailing {
        switch self {
        case .ok(let remaining), .expiring(let remaining): .timeLeft(timeLeftText(remaining, locale: locale))
        case .expired: .stateWord("Expired")
        case .loggedOut: .stateWord("Logged out")
        case .stillValid: .stateWord("Still valid")
        case .unknown: .stateWord("No timer")
        }
    }

    /// The state VoiceOver reads, or `nil` for a timer it reads only as "No timer".
    var spokenState: String? {
        switch self {
        case .ok: "logged in"
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
        case .loggedOut, .stillValid: nil
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
