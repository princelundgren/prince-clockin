import Foundation
import os
import Testing
import PrinceClockInCore

private let hour: TimeInterval = 3600
private let launch = at("2026-11-17T09:00:00Z")
private let authError = ProcessOutcome.exited(
    code: 1, output: "Error: error getting token: cache: no cached credentials; run `databricks auth login` to sign in\n")

private func aws(
    _ name: String, loginTime: Date? = nil, lastAWSCache: AWSCacheRecord? = nil
) -> Login {
    Login(
        displayName: name, kind: .awsSSOSession(name: name), sessionLength: 8 * hour,
        loginTime: loginTime, lastAWSCache: lastAWSCache)
}

/// A Databricks login with a 24 hour session whose timer ends `remaining` seconds after launch.
private func databricks(_ name: String, remaining: TimeInterval) -> Login {
    Login(
        displayName: name, kind: .databricksProfile(name: name, accountLevel: false),
        sessionLength: 24 * hour, loginTime: launch.addingTimeInterval(remaining - 24 * hour))
}

private func custom(command: String?) -> Login {
    Login(displayName: "vpn", kind: .custom(command: command), sessionLength: 8 * hour)
}

private func snapshot(modified: Date, expiresAt: Date) -> AWSCacheState {
    .present(AWSCacheSnapshot(modified: modified, expiresAt: expiresAt, refreshTokenHash: Data([1])))
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    func advance(by interval: TimeInterval) { lock.withLock { current = current.addingTimeInterval(interval) } }
    func read() -> Date { lock.withLock { current } }
}

/// Records each run's arguments and answers it with `respond`.
private final class ArgumentRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private let respond: @Sendable ([String]) async -> ProcessOutcome

    init(respond: @escaping @Sendable ([String]) async -> ProcessOutcome = { _ in .exited(code: 0, output: "") }) {
        self.respond = respond
    }

    var calls: [[String]] { lock.withLock { recorded } }

    func run(
        executable: URL, arguments: [String], environment: [String: String], timeout: Duration
    ) async -> ProcessOutcome {
        lock.withLock { recorded.append(arguments) }
        return await respond(arguments)
    }
}

/// Suspends until the calling task is cancelled, as a CLI waiting on a browser sign-in does.
private func hangUntilCancelled() async -> ProcessOutcome {
    try? await Task.sleep(for: .seconds(3600))
    return .cancelled
}

private final class FakeAWSReader: AWSCacheReading, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [String: AWSCacheState] = [:]

    func set(_ session: String, _ state: AWSCacheState) { lock.withLock { states[session] = state } }

    /// A session with no state set has no cache file.
    func state(session: String, previous: AWSCacheState) -> AWSCacheState {
        lock.withLock { states[session] ?? .missing }
    }
}

private final class FakeNotifier: Notifying, @unchecked Sendable {
    private let lock = NSLock()
    private var postedWarnings: [[Login]] = []
    private var postedDone: [Login] = []
    /// Each save-failed post's reason, as it is posted.
    let saveFailures: AsyncStream<String>
    private let saveFailureSink: AsyncStream<String>.Continuation

    init() {
        (saveFailures, saveFailureSink) = AsyncStream.makeStream(of: String.self)
    }

    var warnings: [[Login]] { lock.withLock { postedWarnings } }
    var customDone: [Login] { lock.withLock { postedDone } }

    func postWarning(logins: [Login]) async { lock.withLock { postedWarnings.append(logins) } }
    func postCustomDone(login: Login) async { lock.withLock { postedDone.append(login) } }
    func postSaveFailed(reason: String) async { saveFailureSink.yield(reason) }
}

private final class FakeApprovals: ApprovalStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: Set<String> = []

    var approved: Set<String> { lock.withLock { keys } }

    func isApproved(_ key: String) -> Bool { lock.withLock { keys.contains(key) } }
    func approve(_ key: String) { _ = lock.withLock { keys.insert(key) } }
}

private final class RecordingTerminal: TerminalOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var opened: [String] = []

    var commands: [String] { lock.withLock { opened } }

    func open(command: String) async throws { lock.withLock { opened.append(command) } }
}

/// What one test's coordinators share: the store directory, the clock and the fakes. Each
/// `makeCoordinator` builds a new queue, resolver and checker, as a relaunch does.
@MainActor
private final class Fixture {
    let directory: URL
    let clock = TestClock(launch)
    let aws = FakeAWSReader()
    let notifier = FakeNotifier()
    let approvals = FakeApprovals()
    let terminal = RecordingTerminal()
    let loginRunner: ArgumentRunner
    let checkRunner: ArgumentRunner
    let configPaths: ConfigPaths
    private let bin: URL

    init(
        logins: [Login] = [],
        loginRunner: ArgumentRunner = ArgumentRunner(),
        checkRunner: ArgumentRunner = ArgumentRunner()
    ) throws {
        directory = try makeTemporaryDirectory()
        bin = try makeTemporaryDirectory()
        try makeExecutable(named: "aws", in: bin)
        try makeExecutable(named: "databricks", in: bin)
        configPaths = ConfigPaths(
            awsConfig: directory.appending(path: "aws-config"),
            databricksConfig: directory.appending(path: "databrickscfg"))
        self.loginRunner = loginRunner
        self.checkRunner = checkRunner
        if !logins.isEmpty { try StateStore(directory: directory).save(AppState(logins: logins)) }
    }

    var stored: AppState? {
        if case .loaded(let state) = StateStore(directory: directory).load() { return state }
        return nil
    }

    func makeCoordinator(store: StateStore? = nil) -> Coordinator {
        let clock = clock
        let resolver = ShellPathResolver(
            runner: ArgumentRunner { [bin] _ in pathOutput(bin.path) },
            shell: URL(fileURLWithPath: "/bin/zsh"), environment: [:])
        let queue = LoginQueue(
            runner: loginRunner, pathResolver: resolver, terminal: terminal, clock: { clock.read() })
        let checker = DatabricksChecker(runner: checkRunner, pathResolver: resolver, clock: { clock.read() })
        return Coordinator(
            store: store ?? StateStore(directory: directory), queue: queue, pathResolver: resolver,
            checker: checker, aws: aws, notifier: notifier, approvals: approvals,
            configPaths: configPaths, clock: { clock.read() })
    }
}

/// Polls `condition` until it holds or two seconds pass. The coordinator applies queue events on
/// its own task, so a test can only wait for their effect.
@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

private extension Coordinator {
    func login(_ id: UUID) -> Login? {
        model.state.logins.first { $0.id == id }
    }

    var batchState: BatchState {
        BatchState(running: running, queued: queued, outcomes: outcomes, batch: batch)
    }
}

/// Every field the coordinator publishes about the running batch, compared at once.
private struct BatchState: Equatable {
    var running: UUID?
    var queued: [UUID] = []
    var outcomes: [LoginOutcome] = []
    var batch: BatchProgress?

    static let idle = BatchState()
}

/// Waits for the coordinator's batch fields to reach `expected`, then checks them, so a failure
/// shows the difference.
@MainActor
private func expectBatch(
    _ coordinator: Coordinator, _ expected: BatchState, sourceLocation: SourceLocation = #_sourceLocation
) async {
    _ = await eventually { coordinator.batchState == expected }
    #expect(coordinator.batchState == expected, sourceLocation: sourceLocation)
}

/// Runs each AWS login once its session's gate opens, answering with `outcomes[session]`, or
/// success. A session in `hanging` instead waits until it is cancelled.
private final class GatedLogins: Sendable {
    private let gates: [String: Gate]
    private let outcomes: [String: ProcessOutcome]
    private let hanging: Set<String>

    init(_ sessions: [String], outcomes: [String: ProcessOutcome] = [:], hanging: Set<String> = []) {
        gates = Dictionary(uniqueKeysWithValues: sessions.map { ($0, Gate()) })
        self.outcomes = outcomes
        self.hanging = hanging
    }

    func release(_ session: String) async {
        await gates[session]?.open()
    }

    var runner: ArgumentRunner {
        ArgumentRunner { [gates, outcomes, hanging] arguments in
            let session = arguments.last?.replacingOccurrences(of: "--sso-session=", with: "") ?? ""
            if hanging.contains(session) { return await hangUntilCancelled() }
            await gates[session]?.wait()
            return outcomes[session] ?? .exited(code: 0, output: "")
        }
    }
}

@MainActor
@Suite struct CoordinatorTests {
    // MARK: Launch

    @Test func baselineMarksMissingCacheLoggedOut() async throws {
        let dev = aws(
            "dev", loginTime: launch.addingTimeInterval(-hour),
            lastAWSCache: AWSCacheRecord(modified: launch.addingTimeInterval(-hour), expiresAt: launch))
        let fixture = try Fixture(logins: [dev])
        let coordinator = fixture.makeCoordinator()

        await coordinator.start()

        let after = try #require(coordinator.login(dev.id))
        #expect(after.invalidatedAt == launch)
        #expect(timerState(for: after, now: launch, leadTime: 0) == .expired)
        #expect(after.lastAWSCache == nil)
        #expect(fixture.stored?.logins.first?.invalidatedAt == launch)
    }

    @Test func baselineLeavesNeverSeenSessionUnknown() async throws {
        let dev = aws("dev")
        let prod = aws("prod")
        let fixture = try Fixture(logins: [dev, prod])
        fixture.aws.set("prod", snapshot(modified: launch.addingTimeInterval(-60), expiresAt: launch.addingTimeInterval(hour)))
        let coordinator = fixture.makeCoordinator()

        await coordinator.start()

        for id in [dev.id, prod.id] {
            let after = try #require(coordinator.login(id))
            #expect(after.invalidatedAt == nil)
            #expect(timerState(for: after, now: launch, leadTime: 0) == .unknown)
        }
    }

    @Test func launchFindsLoginDoneWhileClosed() async throws {
        let seen = launch.addingTimeInterval(-hour)
        let dev = aws("dev", loginTime: seen, lastAWSCache: AWSCacheRecord(modified: seen, expiresAt: launch))
        let fixture = try Fixture(logins: [dev])
        let rewrite = launch.addingTimeInterval(-40 * 60)
        fixture.aws.set("dev", snapshot(modified: rewrite, expiresAt: rewrite.addingTimeInterval(hour)))
        let coordinator = fixture.makeCoordinator()

        await coordinator.start()

        let after = try #require(coordinator.login(dev.id))
        #expect(after.loginTime == rewrite)
        #expect(after.lastAWSCache == AWSCacheRecord(modified: rewrite, expiresAt: rewrite.addingTimeInterval(hour)))
        #expect(fixture.stored?.logins.first?.loginTime == rewrite)
    }

    @Test func launchFindsLoginAfterLogoutSeenBeforeClosing() async throws {
        let seen = launch.addingTimeInterval(-hour)
        let dev = aws("dev", loginTime: seen, lastAWSCache: AWSCacheRecord(modified: seen, expiresAt: launch))
        let fixture = try Fixture(logins: [dev])
        await fixture.makeCoordinator().start()
        fixture.clock.advance(by: 12 * hour)
        let relaunch = fixture.clock.read()
        let login = relaunch.addingTimeInterval(-10 * 60)
        fixture.aws.set("dev", snapshot(modified: login, expiresAt: login.addingTimeInterval(hour)))
        let coordinator = fixture.makeCoordinator()

        await coordinator.start()

        let after = try #require(coordinator.login(dev.id))
        #expect(after.loginTime == login)
        #expect(timerState(for: after, now: relaunch, leadTime: 0) == .ok(remaining: 8 * hour - 10 * 60))
    }

    @Test func initLoadsStateBeforeStart() throws {
        let dev = aws("dev", loginTime: launch)
        let fixture = try Fixture(logins: [dev])

        let coordinator = fixture.makeCoordinator()

        #expect(coordinator.model.state.logins == [dev])
        #expect(coordinator.loadNotice == nil)
    }

    @Test func corruptStoreSetsNotice() throws {
        let fixture = try Fixture()
        try "not json".write(to: fixture.directory.appending(path: "state.json"), atomically: true, encoding: .utf8)

        let coordinator = fixture.makeCoordinator()

        let notice = try #require(coordinator.loadNotice)
        #expect(FileManager.default.fileExists(atPath: notice.path))
        #expect(coordinator.model.state.logins.isEmpty)
    }

    // MARK: Ticks

    @Test func tickAdvancesNow() async throws {
        let fixture = try Fixture()
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()

        fixture.clock.advance(by: 30)
        await coordinator.tick()

        #expect(coordinator.now == launch.addingTimeInterval(30))
    }

    @Test func tickDetectsTerminalLogin() async throws {
        let dev = aws("dev")
        let fixture = try Fixture(logins: [dev])
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()

        let loggedIn = launch.addingTimeInterval(60)
        fixture.aws.set("dev", snapshot(modified: loggedIn, expiresAt: loggedIn.addingTimeInterval(hour)))
        fixture.clock.advance(by: 120)
        await coordinator.tick()

        #expect(coordinator.login(dev.id)?.loginTime == loggedIn)
        #expect(fixture.stored?.logins.first?.loginTime == loggedIn)
    }

    @Test func tickPostsOneGroupedWarning() async throws {
        let dev = login(remaining: 3 * hour + 600, now: launch, name: "dev")
        let prod = login(remaining: 3 * hour + 1200, now: launch, name: "prod")
        let fixture = try Fixture(logins: [dev, prod])
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        await coordinator.tick()
        #expect(fixture.notifier.warnings.isEmpty)

        fixture.clock.advance(by: 3 * hour)
        await coordinator.tick()

        #expect(fixture.notifier.warnings.map { $0.map(\.id) } == [[dev.id, prod.id]])
    }

    @Test func relaunchDoesNotRewarn() async throws {
        let dev = login(remaining: 600, now: launch, name: "dev")
        let fixture = try Fixture(logins: [dev])
        let first = fixture.makeCoordinator()
        await first.start()
        await first.tick()
        #expect(fixture.notifier.warnings.count == 1)

        let relaunched = fixture.makeCoordinator()
        await relaunched.start()
        await relaunched.tick()

        #expect(fixture.notifier.warnings.count == 1)
    }

    @Test func tickChecksDatabricksOnlyWhenWarning() async throws {
        let expiring = databricks("analytics-dev", remaining: 600)
        let fine = databricks("analytics-prod", remaining: 5 * hour)
        let fixture = try Fixture(logins: [expiring, fine])
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()

        await coordinator.tick()
        fixture.clock.advance(by: 600)
        await coordinator.tick()

        #expect(fixture.checkRunner.calls == [["current-user", "me", "--profile", "analytics-dev"]])
    }

    @Test func invalidDatabricksCheckBeforeWarningPostsExpired() async throws {
        let expiring = databricks("analytics-dev", remaining: 600)
        let fixture = try Fixture(logins: [expiring], checkRunner: ArgumentRunner { _ in authError })
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()

        await coordinator.tick()

        let posted = try #require(fixture.notifier.warnings.first)
        #expect(posted.first?.invalidatedAt == launch)
        #expect(warningContent(posted, now: launch, locale: Locale(identifier: "en_GB")).title == "analytics-dev expired")
    }

    @Test func overlappingTickIsSkipped() async throws {
        let gate = Gate()
        let expiring = databricks("analytics-dev", remaining: 600)
        let fixture = try Fixture(
            logins: [expiring],
            checkRunner: ArgumentRunner { _ in
                await gate.wait()
                return .exited(code: 0, output: "")
            })
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        let first = Task { await coordinator.tick() }
        #expect(await eventually { fixture.checkRunner.calls.count == 1 })

        fixture.clock.advance(by: 30)
        await coordinator.tick()
        #expect(coordinator.now == launch)

        await gate.open()
        await first.value
        await coordinator.tick()
        #expect(coordinator.now == launch.addingTimeInterval(30))
        #expect(fixture.checkRunner.calls.count == 1)
        #expect(fixture.notifier.warnings.count == 1)
    }

    @Test func noDatabricksCheckWhileDatabricksLoginRuns() async throws {
        let expiring = databricks("analytics-dev", remaining: 600)
        let fixture = try Fixture(logins: [expiring], loginRunner: ArgumentRunner { _ in await hangUntilCancelled() })
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        coordinator.logIn([expiring.id])
        #expect(await eventually { coordinator.batch != nil })

        await coordinator.tick()

        #expect(fixture.checkRunner.calls.isEmpty)
        #expect(fixture.notifier.warnings.count == 1)
        coordinator.cancelBatch()
    }

    @Test func checkNowChecksEveryDatabricksLogin() async throws {
        let dev = databricks("analytics-dev", remaining: 5 * hour)
        let prod = databricks("analytics-prod", remaining: 5 * hour)
        let fixture = try Fixture(logins: [dev, aws("dev"), prod])
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()

        await coordinator.checkNow()

        #expect(fixture.checkRunner.calls.map(\.last) == ["analytics-dev", "analytics-prod"])
    }

    @Test func checkNowIsPublishedWhileItRuns() async throws {
        let gate = Gate()
        let dev = databricks("analytics-dev", remaining: 5 * hour)
        let fixture = try Fixture(logins: [dev], checkRunner: ArgumentRunner { _ in
            await gate.wait()
            return .exited(code: 0, output: "")
        })
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        #expect(!coordinator.isCheckingDatabricks && coordinator.canCheckDatabricksNow)

        let check = Task { await coordinator.checkNow() }
        #expect(await eventually { fixture.checkRunner.calls.count == 1 })
        #expect(coordinator.isCheckingDatabricks && !coordinator.canCheckDatabricksNow)

        await gate.open()
        await check.value
        #expect(!coordinator.isCheckingDatabricks && coordinator.canCheckDatabricksNow)
    }

    @Test func theWarningTimeCheckIsPublishedWhileItRuns() async throws {
        let gate = Gate()
        let expiring = databricks("analytics-dev", remaining: 600)
        let fixture = try Fixture(logins: [expiring], checkRunner: ArgumentRunner { _ in
            await gate.wait()
            return .exited(code: 0, output: "")
        })
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()

        let tick = Task { await coordinator.tick() }
        #expect(await eventually { fixture.checkRunner.calls.count == 1 })
        #expect(coordinator.isCheckingDatabricks)

        await gate.open()
        await tick.value
        #expect(!coordinator.isCheckingDatabricks)
    }

    @Test func checkNowNeedsAWorkspaceProfile() async throws {
        let account = Login(
            displayName: "analytics-account", kind: .databricksProfile(name: "analytics-account", accountLevel: true))
        let fixture = try Fixture(logins: [aws("dev"), account])
        let coordinator = fixture.makeCoordinator()
        #expect(!coordinator.canCheckDatabricksNow)

        coordinator.addLogin(databricks("analytics-dev", remaining: 5 * hour))

        #expect(coordinator.canCheckDatabricksNow)
    }

    @Test func checkNowWaitsForADatabricksLogin() async throws {
        let dev = databricks("analytics-dev", remaining: 5 * hour)
        let fixture = try Fixture(logins: [dev], loginRunner: ArgumentRunner { _ in await hangUntilCancelled() })
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()

        coordinator.logIn([dev.id])
        #expect(await eventually { !coordinator.canCheckDatabricksNow })

        coordinator.cancelBatch()
        #expect(await eventually { coordinator.canCheckDatabricksNow })
    }

    @Test func checkNowStoresCouldntCheck() async throws {
        let dev = databricks("analytics-dev", remaining: 5 * hour)
        let fixture = try Fixture(logins: [dev], checkRunner: ArgumentRunner { _ in .timedOut(output: "") })
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()

        await coordinator.checkNow()

        let couldntCheck = DatabricksCheckRecord(at: launch, result: .couldntCheck)
        #expect(coordinator.login(dev.id)?.lastDatabricksCheck == couldntCheck)
        #expect(fixture.stored?.logins.first?.lastDatabricksCheck == couldntCheck)
    }

    @Test func aSkippedCheckKeepsTheLastCheck() async throws {
        let dev = databricks("analytics-dev", remaining: 5 * hour)
        let fixture = try Fixture(logins: [dev])
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        await coordinator.checkNow()

        fixture.clock.advance(by: 60)
        await coordinator.checkNow()

        #expect(coordinator.login(dev.id)?.lastDatabricksCheck == DatabricksCheckRecord(at: launch, result: .valid))
        #expect(fixture.checkRunner.calls.count == 1)
    }

    // MARK: Logging in

    @Test func logInKeepsOrder() async throws {
        let dev = aws("dev")
        let prod = aws("prod")
        let fixture = try Fixture(logins: [dev, prod])
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()

        coordinator.logIn([dev.id])
        coordinator.logIn([prod.id])

        #expect(await eventually { coordinator.login(prod.id)?.loginTime != nil })
        #expect(fixture.loginRunner.calls.map(\.last) == ["--sso-session=dev", "--sso-session=prod"])
    }

    @Test func cancelAfterLogInDoesNotOvertake() async throws {
        let dev = aws("dev")
        let prod = aws("prod")
        let fixture = try Fixture(
            logins: [dev, prod],
            loginRunner: ArgumentRunner { arguments in
                arguments.last == "--sso-session=dev" ? await hangUntilCancelled() : .exited(code: 0, output: "")
            })
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()

        coordinator.logIn([dev.id])
        coordinator.cancelBatch()
        coordinator.logIn([prod.id])

        // Had the cancel overtaken the first enqueue, dev would still hang and prod never start.
        #expect(await eventually { coordinator.login(prod.id)?.loginTime != nil })
        #expect(coordinator.login(dev.id)?.loginTime == nil)
    }

    @Test func queueSuccessIsSaved() async throws {
        let dev = aws("dev")
        let fixture = try Fixture(logins: [dev])
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()

        coordinator.logIn([dev.id])

        #expect(await eventually { coordinator.login(dev.id)?.loginTime == launch })
        #expect(fixture.stored?.logins.first?.loginTime == launch)
    }

    @Test func waitingCustomIDFollowsQueue() async throws {
        let vpn = custom(command: nil)
        let fixture = try Fixture(logins: [vpn])
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()

        coordinator.logIn([vpn.id])
        #expect(await eventually {
            coordinator.waitingCustomID == vpn.id && fixture.notifier.customDone.map(\.id) == [vpn.id]
        })

        coordinator.confirmCustomDone(id: vpn.id)
        #expect(await eventually { coordinator.waitingCustomID == nil && coordinator.login(vpn.id)?.loginTime != nil })
    }

    @Test func finishedClearsBatchAndWaiting() async throws {
        let vpn = custom(command: nil)
        let fixture = try Fixture(logins: [vpn])
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        coordinator.logIn([vpn.id])
        #expect(await eventually {
            coordinator.waitingCustomID == vpn.id && coordinator.batch == BatchProgress(position: 1, total: 1)
        })

        coordinator.cancelBatch()

        #expect(await eventually { coordinator.batch == nil && coordinator.waitingCustomID == nil })
    }

    @Test func failureIsKeptUntilTheNextRunOfThatLogin() async throws {
        let dev = aws("dev")
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let fixture = try Fixture(logins: [dev], loginRunner: ArgumentRunner { _ in
            attempts.withLock { $0 += 1; return $0 } == 1 ? .exited(code: 1, output: "denied") : .exited(code: 0, output: "")
        })
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()

        coordinator.logIn([dev.id])
        #expect(await eventually { coordinator.lastFailures[dev.id] == .exitCode(1) && coordinator.batch == nil })

        coordinator.logIn([dev.id])
        #expect(await eventually { coordinator.lastFailures[dev.id] == nil && coordinator.login(dev.id)?.loginTime != nil })
    }

    @Test func removingALoginTakesItOutOfItsPresetsAndSaves() async throws {
        let dev = aws("dev")
        let prod = aws("prod")
        let preset = Preset(name: "Morning", loginIDs: [dev.id, prod.id])
        let fixture = try Fixture()
        let coordinator = fixture.makeCoordinator()
        coordinator.addLogin(dev)
        coordinator.addLogin(prod)
        coordinator.savePreset(preset)

        coordinator.removeLogin(id: dev.id)

        #expect(fixture.stored?.presets.map(\.loginIDs) == [[prod.id]])
    }

    @Test func removingALoginForgetsItsFailure() async throws {
        let dev = aws("dev")
        let fixture = try Fixture(logins: [dev], loginRunner: ArgumentRunner { _ in .exited(code: 1, output: "") })
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        coordinator.logIn([dev.id])
        #expect(await eventually { coordinator.lastFailures[dev.id] != nil })

        coordinator.removeLogin(id: dev.id)

        #expect(coordinator.lastFailures[dev.id] == nil)
    }

    @Test func removingTheRunningLoginCancelsItAndRunsTheNext() async throws {
        let dev = aws("dev")
        let prod = aws("prod")
        let fixture = try Fixture(
            logins: [dev, prod],
            loginRunner: ArgumentRunner { arguments in
                arguments.last == "--sso-session=dev" ? await hangUntilCancelled() : .exited(code: 0, output: "")
            })
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        coordinator.logIn([dev.id, prod.id])
        #expect(await eventually { fixture.loginRunner.calls.count == 1 })

        coordinator.removeLogin(id: dev.id)

        #expect(await eventually { coordinator.login(prod.id)?.loginTime == launch })
    }

    // MARK: The batch's published state

    @Test func twoLoginBatchPublishesEachStep() async throws {
        let dev = aws("dev")
        let prod = aws("prod")
        let logins = GatedLogins(["dev", "prod"], outcomes: ["dev": .exited(code: 1, output: "")])
        let fixture = try Fixture(logins: [dev, prod], loginRunner: logins.runner)
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        #expect(coordinator.batchState == .idle)

        coordinator.logIn([dev.id, prod.id])
        await expectBatch(coordinator, BatchState(
            running: dev.id, queued: [prod.id], batch: BatchProgress(position: 1, total: 2)))

        await logins.release("dev")
        await expectBatch(coordinator, BatchState(
            running: prod.id, outcomes: [.failed(id: dev.id, reason: .exitCode(1))],
            batch: BatchProgress(position: 2, total: 2)))

        await logins.release("prod")
        await expectBatch(coordinator, .idle)
        #expect(coordinator.lastFailures[dev.id] == .exitCode(1))
    }

    @Test func midRunEnqueueJoinsTheQueueAndGrowsTheTotal() async throws {
        let dev = aws("dev")
        let prod = aws("prod")
        let logins = GatedLogins(["dev", "prod"])
        let fixture = try Fixture(logins: [dev, prod], loginRunner: logins.runner)
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        coordinator.logIn([dev.id])
        await expectBatch(coordinator, BatchState(running: dev.id, batch: BatchProgress(position: 1, total: 1)))

        coordinator.logIn([prod.id])
        await expectBatch(coordinator, BatchState(
            running: dev.id, queued: [prod.id], batch: BatchProgress(position: 1, total: 2)))

        await logins.release("dev")
        await expectBatch(coordinator, BatchState(
            running: prod.id, outcomes: [.succeeded(id: dev.id)], batch: BatchProgress(position: 2, total: 2)))
        await logins.release("prod")
        await expectBatch(coordinator, .idle)
    }

    @Test func removingAQueuedLoginShrinksTheBatch() async throws {
        let dev = aws("dev")
        let prod = aws("prod")
        let staging = aws("staging")
        let logins = GatedLogins(["dev", "prod", "staging"])
        let fixture = try Fixture(logins: [dev, prod, staging], loginRunner: logins.runner)
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        coordinator.logIn([dev.id, prod.id, staging.id])
        await expectBatch(coordinator, BatchState(
            running: dev.id, queued: [prod.id, staging.id], batch: BatchProgress(position: 1, total: 3)))

        coordinator.removeLogin(id: prod.id)

        #expect(coordinator.queued == [staging.id])
        await expectBatch(coordinator, BatchState(
            running: dev.id, queued: [staging.id], batch: BatchProgress(position: 1, total: 2)))
        await logins.release("dev")
        await expectBatch(coordinator, BatchState(
            running: staging.id, outcomes: [.succeeded(id: dev.id)], batch: BatchProgress(position: 2, total: 2)))
        await logins.release("staging")
        await expectBatch(coordinator, .idle)
    }

    @Test func removingTheRunningLoginKeepsNoOutcomeForIt() async throws {
        let dev = aws("dev")
        let prod = aws("prod")
        let logins = GatedLogins(["prod"], hanging: ["dev"])
        let fixture = try Fixture(logins: [dev, prod], loginRunner: logins.runner)
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        coordinator.logIn([dev.id, prod.id])
        await expectBatch(coordinator, BatchState(
            running: dev.id, queued: [prod.id], batch: BatchProgress(position: 1, total: 2)))

        coordinator.removeLogin(id: dev.id)

        #expect(coordinator.running == nil)
        await expectBatch(coordinator, BatchState(running: prod.id, batch: BatchProgress(position: 2, total: 2)))
        await logins.release("prod")
        await expectBatch(coordinator, .idle)
    }

    @Test func removingALoginForgetsItsOutcome() async throws {
        let dev = aws("dev")
        let prod = aws("prod")
        let logins = GatedLogins(["dev", "prod"])
        let fixture = try Fixture(logins: [dev, prod], loginRunner: logins.runner)
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        coordinator.logIn([dev.id, prod.id])
        await logins.release("dev")
        await expectBatch(coordinator, BatchState(
            running: prod.id, outcomes: [.succeeded(id: dev.id)], batch: BatchProgress(position: 2, total: 2)))

        coordinator.removeLogin(id: dev.id)

        #expect(coordinator.outcomes.isEmpty)
        await logins.release("prod")
        await expectBatch(coordinator, .idle)
    }

    @Test func cancelAllResetsTheBatch() async throws {
        let dev = aws("dev")
        let prod = aws("prod")
        let logins = GatedLogins(["prod"], hanging: ["dev"])
        let fixture = try Fixture(logins: [dev, prod], loginRunner: logins.runner)
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        coordinator.logIn([dev.id, prod.id])
        await expectBatch(coordinator, BatchState(
            running: dev.id, queued: [prod.id], batch: BatchProgress(position: 1, total: 2)))

        coordinator.cancelBatch()

        await expectBatch(coordinator, .idle)
        #expect(fixture.loginRunner.calls.count == 1)
    }

    @Test func cancellingALoginIsNotAFailure() async throws {
        let dev = aws("dev")
        let fixture = try Fixture(logins: [dev], loginRunner: ArgumentRunner { _ in await hangUntilCancelled() })
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        coordinator.logIn([dev.id])
        #expect(await eventually { coordinator.batch != nil })

        coordinator.cancelBatch()

        #expect(await eventually { coordinator.batch == nil })
        #expect(coordinator.lastFailures[dev.id] == nil)
    }

    @Test func logInHoldsBackUnapprovedImportedCommand() async throws {
        let vpn = custom(command: "vpn-connect --profile dev")
        let dev = aws("dev")
        let fixture = try Fixture(logins: [vpn, dev])
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()

        coordinator.logIn([vpn.id])
        #expect(coordinator.pendingApprovals == [vpn.id])
        coordinator.dismissPendingApproval(id: vpn.id)

        let action = notificationAction(actionIdentifier: NotificationActionID.logIn, loginIDs: [vpn.id.uuidString])
        guard case .logIn(let ids)? = action else {
            Issue.record("expected a log-in action, got \(String(describing: action))")
            return
        }
        coordinator.logIn(ids)
        #expect(coordinator.pendingApprovals == [vpn.id])

        // Commands reach the queue in order, so once dev has run, an enqueued vpn would have opened.
        coordinator.logIn([dev.id])
        #expect(await eventually { coordinator.login(dev.id)?.loginTime != nil })
        #expect(fixture.terminal.commands.isEmpty)
    }

    @Test func approveAndLogInRuns() async throws {
        let command = "vpn-connect --profile dev"
        let vpn = custom(command: command)
        let fixture = try Fixture(logins: [vpn])
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        coordinator.logIn([vpn.id])

        coordinator.approveAndLogIn(vpn.id)

        #expect(fixture.approvals.approved == [approvalKey(for: command)])
        #expect(coordinator.pendingApprovals.isEmpty)
        #expect(await eventually { coordinator.waitingCustomID == vpn.id })
        #expect(fixture.terminal.commands == [command])
    }

    @Test func dismissPendingApprovalNeitherRunsNorApproves() async throws {
        let vpn = custom(command: "vpn-connect --profile dev")
        let dev = aws("dev")
        let fixture = try Fixture(logins: [vpn, dev])
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        coordinator.logIn([vpn.id])

        coordinator.dismissPendingApproval(id: vpn.id)

        #expect(coordinator.pendingApprovals.isEmpty)
        #expect(fixture.approvals.approved.isEmpty)
        coordinator.logIn([dev.id])
        #expect(await eventually { coordinator.login(dev.id)?.loginTime != nil })
        #expect(fixture.terminal.commands.isEmpty)
        coordinator.logIn([vpn.id])
        #expect(coordinator.pendingApprovals == [vpn.id])
    }

    // MARK: Edits

    @Test func setCommandApproves() async throws {
        let vpn = custom(command: nil)
        let fixture = try Fixture()
        let coordinator = fixture.makeCoordinator()

        coordinator.addLogin(vpn)
        coordinator.setCommand(id: vpn.id, to: "vpn-connect --profile prod")
        coordinator.addLogin(custom(command: "vpn-connect --profile dev"))

        #expect(fixture.approvals.approved == [
            approvalKey(for: "vpn-connect --profile prod"), approvalKey(for: "vpn-connect --profile dev"),
        ])
    }

    @Test func setCommandEndsPendingApproval() async throws {
        let vpn = custom(command: "vpn-connect --profile dev")
        let fixture = try Fixture(logins: [vpn])
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        coordinator.logIn([vpn.id])

        coordinator.setCommand(id: vpn.id, to: "vpn-connect --profile prod")

        #expect(coordinator.pendingApprovals.isEmpty)
        #expect(fixture.terminal.commands.isEmpty)
    }

    @Test func editsAreSaved() async throws {
        let dev = aws("dev")
        let prod = aws("prod")
        let fixture = try Fixture()
        let coordinator = fixture.makeCoordinator()

        coordinator.addLogin(dev)
        coordinator.addLogin(prod)
        coordinator.rename(id: dev.id, to: "Dev account")
        coordinator.setSessionLength(id: dev.id, to: 4 * hour + 0.5)
        coordinator.markLoggedInNow(id: dev.id)
        coordinator.removeLogin(id: prod.id)
        let preset = Preset(name: "Morning", loginIDs: [dev.id])
        coordinator.savePreset(preset)
        coordinator.updateSettings(Settings(warningLeadTime: 600, loginTimeout: 120))

        let stored = try #require(fixture.stored)
        #expect(stored.logins.map(\.displayName) == ["Dev account"])
        #expect(stored.logins.first?.sessionLength == 4 * hour)
        #expect(stored.logins.first?.loginTime == launch)
        #expect(stored.presets == [preset])
        #expect(stored.settings == Settings(warningLeadTime: 600, loginTimeout: 120))

        coordinator.removePreset(id: preset.id)
        #expect(fixture.stored?.presets.isEmpty == true)
        #expect(coordinator.saveFailure == nil)
    }

    @Test func setTimerIsSaved() async throws {
        let dev = aws("dev")
        let fixture = try Fixture(logins: [dev])
        let coordinator = fixture.makeCoordinator()

        try coordinator.setTimer(id: dev.id, expiresIn: 4 * hour, sessionLength: 12 * hour)

        let stored = try #require(fixture.stored?.logins.first)
        #expect(stored.loginTime == launch.addingTimeInterval(-8 * hour))
        #expect(stored.sessionLength == 12 * hour)
    }

    @Test func refusedSetTimerNeitherChangesNorSaves() async throws {
        let dev = aws("dev", loginTime: launch.addingTimeInterval(-hour))
        let fixture = try Fixture(logins: [dev])
        let coordinator = fixture.makeCoordinator()
        let before = coordinator.model

        #expect(throws: TimerError.inFuture) {
            try coordinator.setTimer(id: dev.id, loggedInAt: launch.addingTimeInterval(60), sessionLength: 12 * hour)
        }

        #expect(coordinator.model == before)
        #expect(fixture.stored == AppState(logins: [dev]))
    }

    @Test func saveFailureIsReported() async throws {
        let fixture = try Fixture()
        let blocker = fixture.directory.appending(path: "not-a-directory")
        try "".write(to: blocker, atomically: true, encoding: .utf8)
        let coordinator = fixture.makeCoordinator(store: StateStore(directory: blocker))

        coordinator.addLogin(aws("dev"))

        #expect(coordinator.saveFailure != nil)
    }

    @Test func aFailingSaveNotifiesOnceUntilASaveWorks() async throws {
        let fixture = try Fixture()
        let storeDirectory = fixture.directory.appending(path: "store")
        let stateFile = storeDirectory.appending(path: "state.json")
        try "".write(to: storeDirectory, atomically: true, encoding: .utf8)
        let coordinator = fixture.makeCoordinator(store: StateStore(directory: storeDirectory))
        var posts = fixture.notifier.saveFailures.makeAsyncIterator()

        coordinator.addLogin(aws("dev"))
        let noDirectory = try #require(coordinator.saveFailure)
        #expect(await posts.next() == noDirectory)

        coordinator.addLogin(aws("prod"))
        try FileManager.default.removeItem(at: storeDirectory)
        coordinator.retrySave()
        #expect(coordinator.saveFailure == nil)
        try FileManager.default.removeItem(at: stateFile)
        try FileManager.default.createDirectory(at: stateFile, withIntermediateDirectories: false)
        coordinator.addLogin(aws("staging"))
        let fileIsADirectory = try #require(coordinator.saveFailure)

        // Assumes the coordinator's posts arrive in the order it starts them: a post for the
        // repeated failure would come before this one.
        #expect(fileIsADirectory != noDirectory)
        #expect(await posts.next() == fileIsADirectory)
    }

    @Test func retrySaveSavesTheUnchangedState() async throws {
        let fixture = try Fixture()
        let blocker = fixture.directory.appending(path: "not-a-directory")
        try "".write(to: blocker, atomically: true, encoding: .utf8)
        let coordinator = fixture.makeCoordinator(store: StateStore(directory: blocker))
        let dev = aws("dev")
        coordinator.addLogin(dev)
        coordinator.retrySave()
        #expect(coordinator.saveFailure != nil)

        try FileManager.default.removeItem(at: blocker)
        coordinator.retrySave()

        #expect(coordinator.saveFailure == nil)
        #expect(StateStore(directory: blocker).load() == .loaded(AppState(logins: [dev])))
    }

    @Test func discoverCandidatesSkipsTracked() async throws {
        let fixture = try Fixture(logins: [
            aws("dev"),
            Login(displayName: "analytics-dev", kind: .databricksProfile(name: "analytics-dev", accountLevel: false)),
        ])
        try """
            [sso-session dev]
            sso_start_url = https://example.awsapps.com/start
            [sso-session prod]
            sso_start_url = https://example.awsapps.com/start
            """.write(to: fixture.configPaths.awsConfig, atomically: true, encoding: .utf8)
        try """
            [analytics-dev]
            host = https://example.cloud.databricks.com
            auth_type = databricks-cli
            [analytics-prod]
            host = https://example.cloud.databricks.com
            auth_type = databricks-cli
            """.write(to: fixture.configPaths.databricksConfig, atomically: true, encoding: .utf8)
        let coordinator = fixture.makeCoordinator()

        let candidates = coordinator.discoverCandidates()

        #expect(candidates.aws == ["prod"])
        #expect(candidates.databricks == [DatabricksProfile(name: "analytics-prod", accountLevel: false)])
    }
}

@Suite struct AWSCacheFileReaderTests {
    @Test func readErrorGivesPrevious() throws {
        let directory = try makeTemporaryDirectory()
        try "not json".write(
            to: awsCacheFile(forSession: "dev", cacheDirectory: directory), atomically: true, encoding: .utf8)
        let reader = AWSCacheFileReader(cacheDirectory: directory)
        let previous = AWSCacheState.present(AWSCacheSnapshot(modified: launch, expiresAt: launch))

        #expect(reader.state(session: "dev", previous: previous) == previous)
        #expect(reader.state(session: "prod", previous: previous) == .missing)
    }
}
