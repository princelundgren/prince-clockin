import Foundation
import Observation

/// Posts the app's notifications.
public protocol Notifying: Sendable {
    /// One grouped notification for logins that entered their warning time, with a "Log In" action.
    func postWarning(logins: [Login]) async
    /// A custom login waits for the user's Done; the notification carries a "Done" action.
    func postCustomDone(login: Login) async
}

/// Reads what an AWS session's cache file shows now.
public protocol AWSCacheReading: Sendable {
    /// The session's state, given what was last seen of it. A file that can't be read gives `previous`.
    func state(session: String, previous: AWSCacheState) -> AWSCacheState
}

/// Reads the sessions' cache files in one directory, normally `~/.aws/sso/cache`.
public struct AWSCacheFileReader: AWSCacheReading {
    public let cacheDirectory: URL

    public init(cacheDirectory: URL) {
        self.cacheDirectory = cacheDirectory
    }

    public func state(session: String, previous: AWSCacheState) -> AWSCacheState {
        let file = awsCacheFile(forSession: session, cacheDirectory: cacheDirectory)
        do {
            return try readCacheState(at: file, previous: previous)
        } catch {
            return previous
        }
    }
}

/// Where a running batch is: the login at `position` of `total`.
public struct BatchProgress: Equatable, Sendable {
    public let position: Int
    public let total: Int

    public init(position: Int, total: Int) {
        self.position = position
        self.total = total
    }
}

/// How one login of the running batch ended.
public enum LoginOutcome: Equatable, Sendable {
    case succeeded(id: UUID)
    case failed(id: UUID, reason: LoginFailure)
    /// Ended by Cancel All.
    case cancelled(id: UUID)

    /// The login that ended.
    public var id: UUID {
        switch self {
        case .succeeded(let id), .failed(let id, _), .cancelled(let id): id
        }
    }

    /// The outcome a queue event reports; `nil` for an event that ends no login.
    init?(_ event: QueueEvent) {
        switch event {
        case .succeeded(let id, _): self = .succeeded(id: id)
        case .failed(let id, .cancelled): self = .cancelled(id: id)
        case .failed(let id, let reason): self = .failed(id: id, reason: reason)
        case .queued, .started, .waitingForDone, .finished: return nil
        }
    }
}

/// The one object the app drives. It owns the model, saves every change, runs the tick and feeds
/// the login queue. The views read it directly.
@MainActor
@Observable
public final class Coordinator {
    private enum QueueCommand: Sendable {
        case enqueue([Login], timeout: TimeInterval)
        case cancel
        case done(UUID)
        case remove(UUID)
    }

    public private(set) var model: LoginsModel
    /// The time of the last tick; the views time every row against it.
    public private(set) var now: Date
    /// Where an unreadable or newer state file was set aside at launch.
    public private(set) var loadNotice: URL?
    /// The running batch's position of its total, or `nil` when the queue is idle.
    public private(set) var batch: BatchProgress?
    /// The login running now.
    public private(set) var running: UUID?
    /// The logins waiting to run, in order. Empty when a batch ends, unless a login was queued
    /// while Cancel All was ending it: that one waits for the next batch.
    public private(set) var queued: [UUID] = []
    /// How each finished login of the running batch ended, in order; empty once the batch ends. A
    /// login no longer tracked has none.
    public private(set) var outcomes: [LoginOutcome] = []
    /// The custom login waiting for the user's Done.
    public private(set) var waitingCustomID: UUID?
    /// Custom logins held back because their command isn't approved on this Mac, in request order.
    public private(set) var pendingApprovals: [UUID] = []
    /// Why each login's last run failed, until it runs again; a run the user cancelled isn't one.
    /// In memory only.
    public private(set) var lastFailures: [UUID: LoginFailure] = [:]
    /// Why the last save failed; `nil` once a save succeeds.
    public private(set) var saveFailure: String?

    private let store: StateStore
    private let queue: LoginQueue
    private let pathResolver: ShellPathResolver
    private let checker: DatabricksChecker
    private let aws: AWSCacheReading
    private let notifier: Notifying
    private let approvals: ApprovalStoring
    private let configPaths: ConfigPaths
    private let clock: () -> Date
    private let commands: AsyncStream<QueueCommand>
    private let commandSink: AsyncStream<QueueCommand>.Continuation

    @ObservationIgnored private var savedState: AppState
    /// The last state read of each AWS login's cache file, with its token hash, in memory only.
    @ObservationIgnored private var awsStates: [UUID: AWSCacheState] = [:]
    @ObservationIgnored private var runningDatabricksID: UUID?
    @ObservationIgnored private var isTicking = false
    @ObservationIgnored private var isStarted = false

    /// Loads the store at once, so a notification action that launches the app finds its logins.
    public init(
        store: StateStore, queue: LoginQueue, pathResolver: ShellPathResolver, checker: DatabricksChecker,
        aws: AWSCacheReading, notifier: Notifying, approvals: ApprovalStoring, configPaths: ConfigPaths,
        clock: @escaping () -> Date
    ) {
        var state = AppState()
        switch store.load() {
        case .loaded(let loaded): state = loaded
        case .empty: break
        case .setAside(let backup): loadNotice = backup
        }
        model = LoginsModel(state: state)
        savedState = state
        now = clock()
        self.store = store
        self.queue = queue
        self.pathResolver = pathResolver
        self.checker = checker
        self.aws = aws
        self.notifier = notifier
        self.approvals = approvals
        self.configPaths = configPaths
        self.clock = clock
        (commands, commandSink) = AsyncStream.makeStream(of: QueueCommand.self)
    }

    deinit {
        commandSink.finish()
    }

    /// Starts applying the queue's events and feeding it commands, takes every AWS session's
    /// baseline, and begins resolving the login shell's `PATH` without waiting for it. Runs once.
    public func start() async {
        guard !isStarted else { return }
        isStarted = true
        Task { [weak self, events = queue.events] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
        }
        Task { [queue, commands] in
            for await command in commands {
                switch command {
                case .enqueue(let logins, let timeout): await queue.enqueue(logins, timeout: timeout)
                case .cancel: await queue.cancel()
                case .done(let id): await queue.confirmCustomDone(id: id)
                case .remove(let id): await queue.remove(id: id)
                }
            }
        }
        observeAWSCaches(now: clock())
        saveIfChanged()
        Task { [pathResolver] in _ = await pathResolver.resolvePath() }
    }

    /// Reads the AWS cache files, takes and saves the warnings due, checks the Databricks logins
    /// among them and posts one grouped notification. A tick that arrives while one runs is skipped.
    public func tick() async {
        guard !isTicking else { return }
        isTicking = true
        defer { isTicking = false }
        let tickTime = clock()
        now = tickTime
        observeAWSCaches(now: tickTime)
        let due = model.takeWarnings(now: tickTime)
        saveIfChanged()
        await check(model.databricksLogins(among: due), now: tickTime)
        let warned = due.compactMap(login)
        if !warned.isEmpty { await notifier.postWarning(logins: warned) }
    }

    /// Checks every tracked Databricks login, for the panel's "Check now".
    public func checkNow() async {
        await check(model.checkNowTargets(), now: clock())
    }

    /// Queues the logins with `ids`, in order, after any already queued. A custom login whose
    /// command isn't approved on this Mac is held back in `pendingApprovals` instead.
    public func logIn(_ ids: [UUID]) {
        var ready: [Login] = []
        for login in ids.compactMap(login) {
            if needsApproval(login, approvals: approvals) {
                if !pendingApprovals.contains(login.id) { pendingApprovals.append(login.id) }
            } else {
                ready.append(login)
            }
        }
        guard !ready.isEmpty else { return }
        commandSink.yield(.enqueue(ready, timeout: model.state.settings.loginTimeout))
    }

    /// The user's "Run it" on a held-back custom login: approves its command, then logs in.
    public func approveAndLogIn(_ id: UUID) {
        guard let login = login(id) else { return }
        if case .custom(let command?) = login.kind { approvals.approve(approvalKey(for: command)) }
        pendingApprovals.removeAll { $0 == id }
        logIn([id])
    }

    /// The user's "Cancel" on a held-back custom login: it neither runs nor is approved.
    public func dismissPendingApproval(id: UUID) {
        pendingApprovals.removeAll { $0 == id }
    }

    /// Ends the running batch and clears the queue.
    public func cancelBatch() {
        commandSink.yield(.cancel)
    }

    /// The user's Done for the custom login waiting for it.
    public func confirmCustomDone(id: UUID) {
        commandSink.yield(.done(id))
    }

    /// The output of the login's last run, kept in memory only.
    public func output(for id: UUID) async -> String? {
        await queue.lastOutput(id: id)
    }

    /// The user's yes to "Logged in at <time>?".
    public func confirmPossibleLogin(id: UUID) {
        model.confirmPossibleLogin(id: id)
        saveIfChanged()
    }

    /// The AWS sessions and Databricks profiles in the config files that aren't tracked yet.
    public func discoverCandidates() -> (aws: [String], databricks: [DatabricksProfile]) {
        var trackedAWS: Set<String> = []
        var trackedDatabricks: Set<String> = []
        for login in model.state.logins {
            switch login.kind {
            case .awsSSOSession(let name): trackedAWS.insert(name)
            case .databricksProfile(let name, _): trackedDatabricks.insert(name)
            case .custom: break
            }
        }
        let awsText = try? String(contentsOf: configPaths.awsConfig, encoding: .utf8)
        let databricksText = try? String(contentsOf: configPaths.databricksConfig, encoding: .utf8)
        return (
            discoverAWSSessions(configText: awsText).filter { !trackedAWS.contains($0) },
            discoverDatabricksProfiles(configText: databricksText).filter { !trackedDatabricks.contains($0.name) }
        )
    }

    // MARK: Edits from the views; each saves.

    /// Set Timer with Expires In; see `LoginsModel.setTimer(id:expiresIn:sessionLength:now:)`.
    /// - Throws: a `TimerError`, leaving the login unchanged.
    public func setTimer(id: UUID, expiresIn: TimeInterval, sessionLength: TimeInterval) throws(TimerError) {
        try model.setTimer(id: id, expiresIn: expiresIn, sessionLength: sessionLength, now: clock())
        saveIfChanged()
    }

    /// Set Timer with Logged In At; see `LoginsModel.setTimer(id:loggedInAt:sessionLength:now:)`.
    /// - Throws: a `TimerError`, leaving the login unchanged.
    public func setTimer(id: UUID, loggedInAt: Date, sessionLength: TimeInterval) throws(TimerError) {
        try model.setTimer(id: id, loggedInAt: loggedInAt, sessionLength: sessionLength, now: clock())
        saveIfChanged()
    }

    public func markLoggedInNow(id: UUID) {
        model.markLoggedInNow(id: id, now: clock())
        saveIfChanged()
    }

    /// Tracks `login`. A custom command added here was typed by the user, so it is approved.
    public func addLogin(_ login: Login) {
        guard self.login(login.id) == nil else { return }
        model.state.logins.append(login)
        if case .custom(let command?) = login.kind { approvals.approve(approvalKey(for: command)) }
        saveIfChanged()
    }

    /// Stops tracking login `id`, takes it out of every preset and the queue, and forgets what is
    /// known of it in memory. A running login is cancelled, and the batch goes on.
    public func removeLogin(id: UUID) {
        commandSink.yield(.remove(id))
        model.removeLogin(id: id)
        queued.removeAll { $0 == id }
        if running == id { running = nil }
        outcomes.removeAll { $0.id == id }
        pendingApprovals.removeAll { $0 == id }
        lastFailures[id] = nil
        awsStates[id] = nil
        saveIfChanged()
    }

    public func rename(id: UUID, to displayName: String) {
        edit(id) { $0.displayName = displayName }
    }

    /// Sets the session length, rounded down to whole seconds.
    public func setSessionLength(id: UUID, to length: TimeInterval?) {
        edit(id) { $0.sessionLength = length.map { $0.rounded(.down) } }
    }

    /// Sets a custom login's command and approves it, since the user typed it. A login held back
    /// for approval no longer waits; it runs on the next log-in.
    public func setCommand(id: UUID, to command: String?) {
        guard let login = login(id), case .custom = login.kind else { return }
        if let command { approvals.approve(approvalKey(for: command)) }
        pendingApprovals.removeAll { $0 == id }
        edit(id) { $0.kind = .custom(command: command) }
    }

    /// Adds `preset`, or replaces the one with its id.
    public func savePreset(_ preset: Preset) {
        if let index = model.state.presets.firstIndex(where: { $0.id == preset.id }) {
            model.state.presets[index] = preset
        } else {
            model.state.presets.append(preset)
        }
        saveIfChanged()
    }

    public func removePreset(id: UUID) {
        model.state.presets.removeAll { $0.id == id }
        saveIfChanged()
    }

    public func updateSettings(_ settings: Settings) {
        model.state.settings = settings
        saveIfChanged()
    }

    // MARK: Private

    private func handle(_ event: QueueEvent) async {
        model.apply(event)
        switch event {
        case .queued(let ids, let total):
            queued = ids
            if let batch { self.batch = BatchProgress(position: batch.position, total: total) }
        case .started(let id, let position, let total):
            batch = BatchProgress(position: position, total: total)
            running = id
            queued.removeAll { $0 == id }
            lastFailures[id] = nil
            if let login = login(id), case .databricksProfile = login.kind { runningDatabricksID = id }
        case .succeeded(let id, _), .failed(let id, _):
            if let outcome = LoginOutcome(event), login(id) != nil {
                outcomes.append(outcome)
                if case .failed(_, let reason) = outcome { lastFailures[id] = reason }
            }
            if running == id { running = nil }
            if waitingCustomID == id { waitingCustomID = nil }
            if runningDatabricksID == id { runningDatabricksID = nil }
        case .waitingForDone(let id):
            waitingCustomID = id
            if let login = login(id) { await notifier.postCustomDone(login: login) }
        case .finished:
            batch = nil
            running = nil
            outcomes = []
            waitingCustomID = nil
            runningDatabricksID = nil
        }
        saveIfChanged()
    }

    /// Compares each AWS login's cache file with what was last seen of it: in memory after the
    /// first read, else the stored record, else missing for a login still marked logged out. A
    /// session with none of these is only read, as a baseline, so one never seen logged in keeps
    /// the timer it has.
    private func observeAWSCaches(now: Date) {
        for login in model.state.logins {
            guard case .awsSSOSession(let session) = login.kind else { continue }
            let previous = awsStates[login.id]
                ?? login.lastAWSCache.map { .present(AWSCacheSnapshot(modified: $0.modified, expiresAt: $0.expiresAt)) }
                ?? (isInvalidated(login) ? .missing : .unread)
            let current = aws.state(session: session, previous: previous)
            let observation = observe(
                previous: previous, current: current, timerExpiry: expiry(of: login),
                leadTime: model.state.settings.warningLeadTime)
            model.apply(observation, login: login.id, now: now)
            awsStates[login.id] = current
            switch current {
            case .present(let snapshot):
                update(login.id) {
                    $0.lastAWSCache = AWSCacheRecord(modified: snapshot.modified, expiresAt: snapshot.expiresAt)
                }
            case .missing:
                update(login.id) { $0.lastAWSCache = nil }
            case .unread:
                break
            }
        }
    }

    /// Checks `logins` one at a time and applies each answer. Skipped checks change nothing.
    private func check(_ logins: [Login], now: Date) async {
        for login in logins {
            guard case .databricksProfile(let profile, let accountLevel) = login.kind else { continue }
            let check = await checker.check(
                profile: profile, accountLevel: accountLevel, loginRunning: runningDatabricksID != nil)
            if let result = check.result { model.apply(result, login: login.id, now: now) }
        }
        saveIfChanged()
    }

    private func login(_ id: UUID) -> Login? {
        model.state.logins.first { $0.id == id }
    }

    private func update(_ id: UUID, _ change: (inout Login) -> Void) {
        guard let index = model.state.logins.firstIndex(where: { $0.id == id }) else { return }
        change(&model.state.logins[index])
    }

    private func edit(_ id: UUID, _ change: (inout Login) -> Void) {
        update(id, change)
        saveIfChanged()
    }

    private func saveIfChanged() {
        guard model.state != savedState else { return }
        do {
            try store.save(model.state)
            savedState = model.state
            saveFailure = nil
        } catch {
            saveFailure = error.localizedDescription
        }
    }
}
