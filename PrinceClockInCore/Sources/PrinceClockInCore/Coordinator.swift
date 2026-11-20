import Foundation
import Observation

/// Posts the app's notifications.
public protocol Notifying: Sendable {
    /// One grouped notification for logins that entered their notification time, with a "Log In" action.
    func postExpiryNotification(logins: [Login]) async
    /// A custom login waits for the user's Done; the notification carries a "Done" action.
    func postCustomDone(login: Login) async
    /// Saving stopped working; `reason` is the system's.
    func postSaveFailed(reason: String) async
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
    /// Whether a login still tracked failed, not by a cancel, since the panel was last shown.
    public var hasUnseenFailure: Bool { !unseenFailures.isEmpty }
    /// The menu bar's row at the last tick. A failed save shows as a failure until a save works,
    /// whether or not the panel has been shown.
    public var menuBarStatus: MenuBarStatus {
        PrinceClockInCore.menuBarStatus(
            model.state.logins, now: now, leadTime: model.state.settings.notificationLeadTime, batch: batch,
            hasFailure: hasUnseenFailure || saveFailure != nil)
    }

    /// The panel's card for the running batch, or `nil` when the queue is idle.
    public var batchCard: BatchCard? {
        batch.map {
            PrinceClockInCore.batchCard(
                batch: $0, running: running.flatMap(login), next: queued.lazy.compactMap(login).first,
                outcomes: outcomes, waitingForDone: waitingCustomID.flatMap(login))
        }
    }

    /// Whether a Databricks check runs now, from the notification time or Check Databricks Now.
    public var isCheckingDatabricks: Bool { runningChecks > 0 }
    /// Whether Check Databricks Now can run: no check or Databricks login runs, and a workspace
    /// profile, which unlike an account profile can be checked, is tracked.
    public var canCheckDatabricksNow: Bool {
        !isCheckingDatabricks && runningDatabricksID == nil
            && model.state.logins.contains { $0.kind.isWorkspaceProfile }
    }

    /// Where discovery reads the AWS and Databricks config files.
    public let configPaths: ConfigPaths

    private let store: StateStore
    private let queue: LoginQueue
    private let pathResolver: ShellPathResolver
    private let checker: DatabricksChecker
    private let aws: AWSCacheReading
    private let notifier: Notifying
    private let approvals: ApprovalStoring
    private let clock: () -> Date
    private let commands: AsyncStream<QueueCommand>
    private let commandSink: AsyncStream<QueueCommand>.Continuation

    @ObservationIgnored private var savedState: AppState
    /// The last state read of each AWS login's cache file, with its token hash, in memory only.
    @ObservationIgnored private var awsStates: [UUID: AWSCacheState] = [:]
    private var runningDatabricksID: UUID?
    private var runningChecks = 0
    private var unseenFailures: Set<UUID> = []
    @ObservationIgnored private var isFirstCheckAfterWake = false
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
    /// baseline, begins resolving the login shell's `PATH` without waiting for it, and reads which
    /// Databricks logins are account profiles from the config file. Runs once.
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
        await rereadAccountLevels()
    }

    /// Reads the AWS cache files, takes and saves the expiry notifications due, checks the
    /// Databricks logins among them and posts one grouped notification. A tick that arrives while
    /// one runs is skipped.
    public func tick() async {
        guard !isTicking else { return }
        isTicking = true
        defer { isTicking = false }
        let tickTime = clock()
        now = tickTime
        observeAWSCaches(now: tickTime, isFirstCheckAfterWake: isFirstCheckAfterWake)
        isFirstCheckAfterWake = false
        let due = model.takeExpiryNotifications(now: tickTime)
        saveIfChanged()
        await check(model.databricksLogins(among: due), now: tickTime)
        let notified = due.compactMap(login)
        if !notified.isEmpty { await notifier.postExpiryNotification(logins: notified) }
    }

    /// Checks every tracked Databricks login, for Check Databricks Now.
    public func checkNow() async {
        await check(model.checkNowTargets(), now: clock())
    }

    /// Queues the logins with `ids`, in order, after any already queued. A custom login whose
    /// command isn't approved on this Mac is held back in `pendingApprovals` instead.
    public func logIn(_ ids: [UUID]) {
        var ready: [Login] = []
        for login in ids.compactMap(login) {
            if PrinceClockInCore.needsApproval(login, approvals: approvals) {
                if !pendingApprovals.contains(login.id) { pendingApprovals.append(login.id) }
            } else {
                ready.append(login)
            }
        }
        guard !ready.isEmpty else { return }
        commandSink.yield(.enqueue(ready, timeout: model.state.settings.loginTimeout))
    }

    /// Whether login `id` is a custom login whose command isn't approved on this Mac, so it won't
    /// run until the user's Run It. `false` for a login not tracked.
    public func needsApproval(id: UUID) -> Bool {
        guard let login = login(id) else { return false }
        return PrinceClockInCore.needsApproval(login, approvals: approvals)
    }

    /// The user's "Run it" on a held-back custom login: approves its command, then logs in.
    public func approveAndLogIn(_ id: UUID) {
        guard let login = login(id) else { return }
        if case .custom(let command?) = login.kind { approvals.approve(approvalKey(for: command)) }
        pendingApprovals.removeAll { $0 == id }
        logIn([id])
    }

    /// The user's Not Now on a held-back custom login: it is skipped this time, neither run nor
    /// approved.
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

    /// The user's Dismiss on the State set aside banner; the set-aside file stays where it is.
    public func dismissLoadNotice() {
        loadNotice = nil
    }

    /// The panel was shown, so the user has seen every failure so far.
    public func markPanelShown() {
        unseenFailures.removeAll()
    }

    /// The Mac woke: a login the next tick finds possibly logged in elsewhere says it changed while
    /// the Mac slept. Call it before the wake's tick.
    public func systemDidWake() {
        isFirstCheckAfterWake = true
    }

    /// Login `id`'s tile at the last tick, or `nil` for a login not tracked.
    public func tile(for id: UUID, locale: Locale, calendar: Calendar) -> TilePresentation? {
        guard let login = login(id) else { return nil }
        let activity: TileActivity = running == id ? .running : queued.contains(id) ? .queued : .idle
        let facts = TileFacts(
            activity: activity, failure: lastFailures[id], isAwaitingApproval: pendingApprovals.contains(id),
            possibleLoginAt: model.possibleLogins[id]?.time,
            isPossibleLoginFoundOnWake: model.possibleLogins[id]?.isFoundOnWake ?? false)
        return tilePresentation(
            for: login, now: now, leadTime: model.state.settings.notificationLeadTime, facts: facts,
            locale: locale, calendar: calendar)
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

    /// The AWS sessions and Databricks profiles in the config files that aren't tracked yet. The
    /// files are read off the main actor; what is tracked is checked once they have been read.
    public func discoverCandidates() async -> (aws: [String], databricks: [DatabricksProfile]) {
        let found = await Self.discover(in: configPaths)
        let tracked = TrackedConfigNames(logins: model.state.logins)
        return (
            found.aws.filter { !tracked.aws.contains($0) },
            found.databricks.filter { !tracked.databricks.contains($0.name) }
        )
    }

    /// Every AWS session and Databricks profile in the config files at `paths`.
    @concurrent
    private nonisolated static func discover(
        in paths: ConfigPaths
    ) async -> (aws: [String], databricks: [DatabricksProfile]) {
        let awsText = try? String(contentsOf: paths.awsConfig, encoding: .utf8)
        let databricksText = try? String(contentsOf: paths.databricksConfig, encoding: .utf8)
        return (discoverAWSSessions(configText: awsText), discoverDatabricksProfiles(configText: databricksText))
    }

    // MARK: Edits from the views; each saves.

    /// Set Timer, at the clock's time; see `LoginsModel.setTimer(id:_:now:)`.
    /// - Throws: a `TimerError`, leaving the login unchanged.
    public func setTimer(id: UUID, _ entry: TimerEntry) throws(TimerError) {
        try model.setTimer(id: id, entry, now: clock())
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
        unseenFailures.remove(id)
        pendingApprovals.removeAll { $0 == id }
        lastFailures[id] = nil
        awsStates[id] = nil
        saveIfChanged()
    }

    public func rename(id: UUID, to displayName: String) {
        edit(id) { $0.displayName = displayName }
    }

    /// Sets the session length, rounded down to whole seconds, or makes it unknown with `nil`.
    /// - Throws: `.sessionLengthTooLong` for a length that isn't finite or is longer than
    ///   `maximumSessionLength`, and `.sessionLengthNotPositive` for one of zero or less, or under
    ///   a second, either leaving the session length as it was.
    public func setSessionLength(id: UUID, to length: TimeInterval?) throws(TimerError) {
        let length = try length.map(checkedSessionLength)
        edit(id) { $0.sessionLength = length }
    }

    /// Sets the session length from the session length field's text, as
    /// `sessionLength(fieldText:locale:)` reads it. The text the field shows for the stored length
    /// leaves it exactly as it is.
    /// - Throws: That function's refusal, leaving the session length as it was.
    public func setSessionLength(id: UUID, fieldText: String, locale: Locale) throws(SessionLengthRefusal) {
        let shown = sessionLengthHoursText(login(id)?.sessionLength, locale: locale)
        guard fieldText.trimmingCharacters(in: .whitespaces) != shown else { return }
        let length = try sessionLength(fieldText: fieldText, locale: locale)
        edit(id) { $0.sessionLength = length }
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

    /// Stores the tracked logins in the order `ids` gives; see `LoginsModel.setLoginOrder(_:)`.
    public func setLoginOrder(_ ids: [UUID]) {
        model.setLoginOrder(ids)
        saveIfChanged()
    }

    /// Stores the presets in the order `ids` gives; see `LoginsModel.setPresetOrder(_:)`.
    public func setPresetOrder(_ ids: [UUID]) {
        model.setPresetOrder(ids)
        saveIfChanged()
    }

    public func removePreset(id: UUID) {
        model.state.presets.removeAll { $0.id == id }
        saveIfChanged()
    }

    /// Saves the state again, for the Save Failed banner's Try Again, even if nothing changed since
    /// the save that failed.
    public func retrySave() {
        save()
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
                if case .failed(_, let reason) = outcome {
                    lastFailures[id] = reason
                    unseenFailures.insert(id)
                }
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
    private func observeAWSCaches(now: Date, isFirstCheckAfterWake: Bool = false) {
        for login in model.state.logins {
            guard case .awsSSOSession(let session) = login.kind else { continue }
            let previous = awsStates[login.id]
                ?? login.lastAWSCache.map { .present(AWSCacheSnapshot(modified: $0.modified, expiresAt: $0.expiresAt)) }
                ?? (isInvalidated(login) ? .missing : .unread)
            let current = aws.state(session: session, previous: previous)
            let observation = observe(
                previous: previous, current: current, timerExpiry: expiry(of: login),
                leadTime: model.state.settings.notificationLeadTime)
            model.apply(observation, login: login.id, now: now, isFirstCheckAfterWake: isFirstCheckAfterWake)
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

    /// Checks `logins` one at a time and applies each answer, after reading which are account
    /// profiles from the config file. Skipped checks change nothing.
    private func check(_ logins: [Login], now: Date) async {
        guard !logins.isEmpty else { return }
        runningChecks += 1
        defer { runningChecks -= 1 }
        await rereadAccountLevels()
        for login in logins.compactMap({ login($0.id) }) {
            guard case .databricksProfile(let profile, let accountLevel) = login.kind else { continue }
            let check = await checker.check(
                profile: profile, accountLevel: accountLevel, loginRunning: runningDatabricksID != nil)
            if let result = check.result { model.apply(result, login: login.id, now: now) }
        }
        saveIfChanged()
    }

    /// Sets each tracked Databricks login's account flag to what the config file says now, and
    /// saves. A profile the file no longer offers keeps its flag.
    private func rereadAccountLevels() async {
        let profiles = await Self.discover(in: configPaths).databricks
        for profile in profiles {
            for index in model.state.logins.indices {
                guard case .databricksProfile(profile.name, let accountLevel) = model.state.logins[index].kind,
                      accountLevel != profile.accountLevel
                else { continue }
                model.state.logins[index].kind = .databricksProfile(name: profile.name, accountLevel: profile.accountLevel)
            }
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
        save()
    }

    /// Posts a notification when saving goes from working to failing, not again while it fails.
    private func save() {
        do {
            try store.save(model.state)
            savedState = model.state
            saveFailure = nil
        } catch {
            let reason = error.localizedDescription
            if saveFailure == nil { Task { [notifier] in await notifier.postSaveFailed(reason: reason) } }
            saveFailure = reason
        }
    }
}

private extension LoginKind {
    var isWorkspaceProfile: Bool {
        if case .databricksProfile(_, accountLevel: false) = self { true } else { false }
    }
}
