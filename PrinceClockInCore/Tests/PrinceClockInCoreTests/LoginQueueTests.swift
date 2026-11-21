import Foundation
import Testing
import PrinceClockInCore

private let zsh = URL(fileURLWithPath: "/bin/zsh")
private let now = at("2026-11-17T09:00:00Z")
private let timeout: TimeInterval = 300
private let shortTimeout: TimeInterval = 0.05

private func awsLogin(_ name: String) -> Login {
    Login(displayName: name, kind: .awsSSOSession(name: name))
}

private func databricksLogin(_ name: String) -> Login {
    Login(displayName: name, kind: .databricksProfile(name: name, accountLevel: false))
}

private func customLogin(command: String?) -> Login {
    Login(displayName: "custom", kind: .custom(command: command))
}

/// A temporary directory holding executables named `aws` and `databricks`.
private func makeCLIDirectory() throws -> URL {
    let directory = try makeTemporaryDirectory()
    try makeExecutable(named: "aws", in: directory)
    try makeExecutable(named: "databricks", in: directory)
    return directory
}

/// A queue whose login shell reports `path` as its only `PATH` directory.
private func makeQueue(
    runner: FakeRunner, terminal: any TerminalOpening = FakeTerminal(), path: URL,
    clock: @escaping @Sendable () -> Date = { now }
) -> LoginQueue {
    let resolver = ShellPathResolver(
        runner: FakeRunner { _ in pathOutput(path.path) }, shell: zsh, environment: [:])
    return LoginQueue(runner: runner, pathResolver: resolver, terminal: terminal, clock: clock)
}

private func succeedingRunner() -> FakeRunner {
    FakeRunner { _ in .exited(code: 0, output: "") }
}

/// Suspends until the calling task is cancelled.
private func waitUntilCancelled() async {
    let cancelled = Gate()
    await withTaskCancellationHandler {
        await cancelled.wait()
    } onCancel: {
        Task { await cancelled.open() }
    }
}

private struct EventReader {
    private var iterator: AsyncStream<QueueEvent>.Iterator

    init(_ queue: LoginQueue) {
        iterator = queue.events.makeAsyncIterator()
    }

    mutating func next(_ count: Int) async -> [QueueEvent] {
        var events: [QueueEvent] = []
        for _ in 0..<count {
            guard let event = await iterator.next() else { break }
            events.append(event)
        }
        return events
    }

    /// The events up to and including the next `.finished`.
    mutating func throughFinished() async -> [QueueEvent] {
        var events: [QueueEvent] = []
        while let event = await iterator.next() {
            events.append(event)
            if event == .finished { break }
        }
        return events
    }
}

private final class FakeTerminal: TerminalOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var opened: [String] = []
    private let failure: (any Error)?
    private let hold: (entered: Gate, release: Gate)?

    /// With `hold`, `open` signals `entered` and returns only once `release` opens.
    init(failure: (any Error)? = nil, hold: (entered: Gate, release: Gate)? = nil) {
        self.failure = failure
        self.hold = hold
    }

    var commands: [String] {
        lock.withLock { opened }
    }

    func open(command: String) async throws {
        lock.withLock { opened.append(command) }
        if let hold {
            await hold.entered.open()
            await hold.release.wait()
        }
        if let failure { throw failure }
    }
}

private struct TerminalNotStarted: LocalizedError {
    var errorDescription: String? { "Terminal couldn't be started" }
}

/// A terminal whose `open` returns only once it is cancelled, and records that it was.
private final class CancelWaitingTerminal: TerminalOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var sawCancel: Bool {
        lock.withLock { cancelled }
    }

    func open(command: String) async throws {
        await waitUntilCancelled()
        lock.withLock { cancelled = true }
    }
}

private final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var entries: [String] {
        lock.withLock { recorded }
    }

    func append(_ entry: String) {
        lock.withLock { recorded.append(entry) }
    }
}

@Suite(.timeLimit(.minutes(1))) struct LoginQueueTests {
    @Test func runsOneAtATimeInOrder() async throws {
        let directory = try makeCLIDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstEntered = Gate()
        let releaseFirst = Gate()
        let steps = StepLog()
        let runner = FakeRunner { index in
            steps.append("start \(index)")
            if index == 0 {
                await firstEntered.open()
                await releaseFirst.wait()
            }
            steps.append("end \(index)")
            return .exited(code: 0, output: "")
        }
        let queue = makeQueue(runner: runner, path: directory)
        var events = EventReader(queue)
        let dev = awsLogin("dev")
        let prod = awsLogin("prod")
        let analytics = databricksLogin("analytics-dev")

        await queue.enqueue([dev, prod, analytics], timeout: timeout)
        await firstEntered.wait()
        // Gives a concurrent queue time to start a second call; a correct one passes at any timing.
        try await Task.sleep(for: .milliseconds(200))
        #expect(runner.calls.count == 1)
        await releaseFirst.open()

        #expect(await events.throughFinished() == [
            .queued(ids: [dev.id, prod.id, analytics.id], total: 3),
            .started(id: dev.id, position: 1, total: 3), .succeeded(id: dev.id, at: now),
            .started(id: prod.id, position: 2, total: 3), .succeeded(id: prod.id, at: now),
            .started(id: analytics.id, position: 3, total: 3), .succeeded(id: analytics.id, at: now),
            .finished,
        ])
        #expect(steps.entries == ["start 0", "end 0", "start 1", "end 1", "start 2", "end 2"])
        #expect(runner.calls.map(\.arguments) == [
            ["sso", "login", "--sso-session=dev"], ["sso", "login", "--sso-session=prod"],
            ["auth", "login", "--profile=analytics-dev"],
        ])
    }

    @Test func runsLocatedExecutableWithArgumentList() async throws {
        let directory = try makeCLIDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = succeedingRunner()
        let queue = makeQueue(runner: runner, path: directory)
        var events = EventReader(queue)
        let hostileName = #"dev; rm -rf ~ "quoted" 'single'"#

        await queue.enqueue([awsLogin(hostileName)], timeout: timeout)
        _ = await events.throughFinished()

        #expect(runner.calls.count == 1)
        let call = try #require(runner.calls.first)
        #expect(call.executable == directory.appendingPathComponent("aws"))
        #expect(call.arguments == ["sso", "login", "--sso-session=\(hostileName)"])
        #expect(call.environment["PATH"] == directory.path)
        #expect(call.environment.filter { $0.key != "PATH" }
            == ProcessInfo.processInfo.environment.filter { $0.key != "PATH" })
        #expect(call.timeout == .seconds(timeout))
    }

    @Test func resolvesPathOncePerLogin() async {
        let shell = FakeRunner { _ in .exited(code: 0, output: "no markers") }
        let resolver = ShellPathResolver(runner: shell, shell: zsh, environment: [:])
        let runner = succeedingRunner()
        let queue = LoginQueue(runner: runner, pathResolver: resolver, terminal: FakeTerminal(), clock: { now })
        var events = EventReader(queue)

        await queue.enqueue([awsLogin("dev"), awsLogin("prod")], timeout: timeout)
        _ = await events.throughFinished()

        // A failed read isn't cached; a second read per login shows only where `aws` is on the fallback PATH.
        #expect(shell.calls.count == 2)
        #expect(runner.calls.allSatisfy {
            $0.environment["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        })
    }

    @Test func duplicateEnqueueIsIgnored() async throws {
        let directory = try makeCLIDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entered = Gate()
        let release = Gate()
        let runner = FakeRunner { index in
            if index == 0 {
                await entered.open()
                await release.wait()
            }
            return .exited(code: 0, output: "")
        }
        let queue = makeQueue(runner: runner, path: directory)
        var events = EventReader(queue)
        let dev = awsLogin("dev")
        let prod = awsLogin("prod")

        await queue.enqueue([dev, prod, dev], timeout: timeout)
        await entered.wait()
        await queue.enqueue([dev, prod], timeout: timeout)
        await release.open()

        #expect(await events.throughFinished() == [
            .queued(ids: [dev.id, prod.id], total: 2),
            .started(id: dev.id, position: 1, total: 2), .succeeded(id: dev.id, at: now),
            .started(id: prod.id, position: 2, total: 2), .succeeded(id: prod.id, at: now),
            .finished,
        ])
        #expect(runner.calls.count == 2)
    }

    @Test func enqueueMidRunGrowsTotal() async throws {
        let directory = try makeCLIDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entered = Gate()
        let release = Gate()
        let runner = FakeRunner { index in
            if index == 0 {
                await entered.open()
                await release.wait()
            }
            return .exited(code: 0, output: "")
        }
        let queue = makeQueue(runner: runner, path: directory)
        var events = EventReader(queue)
        let dev = awsLogin("dev")
        let prod = awsLogin("prod")

        await queue.enqueue([dev], timeout: timeout)
        await entered.wait()
        await queue.enqueue([prod], timeout: timeout)
        await release.open()

        #expect(await events.throughFinished() == [
            .queued(ids: [dev.id], total: 1), .started(id: dev.id, position: 1, total: 1),
            .queued(ids: [prod.id], total: 2), .succeeded(id: dev.id, at: now),
            .started(id: prod.id, position: 2, total: 2), .succeeded(id: prod.id, at: now),
            .finished,
        ])
    }

    @Test func missingCLIFailsImmediately() async throws {
        let emptyDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: emptyDirectory) }
        let runner = succeedingRunner()
        let queue = makeQueue(runner: runner, path: emptyDirectory)
        var events = EventReader(queue)
        let dev = awsLogin("dev")
        let start = ContinuousClock.now

        await queue.enqueue([dev], timeout: timeout)

        #expect(await events.throughFinished() == [
            .queued(ids: [dev.id], total: 1),
            .started(id: dev.id, position: 1, total: 1),
            .failed(id: dev.id, reason: .cliNotFound("aws")),
            .finished,
        ])
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(runner.calls.isEmpty)
    }

    @Test func nonZeroExitIsFailedAndQueueContinues() async throws {
        let directory = try makeCLIDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = FakeRunner { index in
            .exited(code: index == 0 ? 1 : 0, output: "")
        }
        let queue = makeQueue(runner: runner, path: directory)
        var events = EventReader(queue)
        let dev = awsLogin("dev")
        let prod = awsLogin("prod")

        await queue.enqueue([dev, prod], timeout: timeout)

        #expect(await events.throughFinished() == [
            .queued(ids: [dev.id, prod.id], total: 2),
            .started(id: dev.id, position: 1, total: 2), .failed(id: dev.id, reason: .exitCode(1)),
            .started(id: prod.id, position: 2, total: 2), .succeeded(id: prod.id, at: now),
            .finished,
        ])
    }

    @Test func failedRunKeepsItsOutput() async throws {
        let directory = try makeCLIDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = FakeRunner { _ in .exited(code: 255, output: "Error loading SSO Token") }
        let queue = makeQueue(runner: runner, path: directory)
        var events = EventReader(queue)
        let dev = awsLogin("dev")

        await queue.enqueue([dev], timeout: timeout)
        _ = await events.throughFinished()

        #expect(await queue.lastOutput(id: dev.id) == "Error loading SSO Token")
        #expect(await queue.lastOutput(id: UUID()) == nil)
    }

    @Test func aSignalIsItsOwnFailureAndKeepsTheOutput() async throws {
        let directory = try makeCLIDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = FakeRunner { _ in .signalled(signal: 9, output: "Opening the browser") }
        let queue = makeQueue(runner: runner, path: directory)
        var events = EventReader(queue)
        let dev = awsLogin("dev")

        await queue.enqueue([dev], timeout: timeout)

        #expect(await events.throughFinished() == [
            .queued(ids: [dev.id], total: 1),
            .started(id: dev.id, position: 1, total: 1), .failed(id: dev.id, reason: .signal(9)), .finished,
        ])
        #expect(await queue.lastOutput(id: dev.id) == "Opening the browser")
    }

    @Test func timeoutIsFailedAndQueueContinues() async throws {
        let directory = try makeCLIDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = FakeRunner { index in
            index == 0 ? .timedOut(output: "") : .exited(code: 0, output: "")
        }
        let queue = makeQueue(runner: runner, path: directory)
        var events = EventReader(queue)
        let dev = awsLogin("dev")
        let prod = awsLogin("prod")

        await queue.enqueue([dev, prod], timeout: timeout)

        #expect(await events.throughFinished() == [
            .queued(ids: [dev.id, prod.id], total: 2),
            .started(id: dev.id, position: 1, total: 2), .failed(id: dev.id, reason: .timedOut),
            .started(id: prod.id, position: 2, total: 2), .succeeded(id: prod.id, at: now),
            .finished,
        ])
    }

    @Test func successEmitsSucceededWithClockTime() async throws {
        let directory = try makeCLIDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let loggedIn = at("2026-11-17T10:15:30Z")
        let queue = makeQueue(runner: succeedingRunner(), path: directory, clock: { loggedIn })
        var events = EventReader(queue)
        let dev = awsLogin("dev")

        await queue.enqueue([dev], timeout: timeout)

        #expect(await events.throughFinished() == [
            .queued(ids: [dev.id], total: 1),
            .started(id: dev.id, position: 1, total: 1), .succeeded(id: dev.id, at: loggedIn), .finished,
        ])
    }

    @Test func customLoginOpensTerminalAndWaitsForDone() async throws {
        let directory = try makeCLIDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let terminal = FakeTerminal()
        let runner = succeedingRunner()
        let queue = makeQueue(runner: runner, terminal: terminal, path: directory)
        var events = EventReader(queue)
        let custom = customLogin(command: "az login")
        let dev = awsLogin("dev")

        await queue.enqueue([custom, dev], timeout: timeout)

        #expect(await events.next(3) == [
            .queued(ids: [custom.id, dev.id], total: 2),
            .started(id: custom.id, position: 1, total: 2), .waitingForDone(id: custom.id),
        ])
        #expect(terminal.commands == ["az login"])
        #expect(runner.calls.isEmpty)
        await queue.confirmCustomDone(id: custom.id)
        #expect(await events.throughFinished() == [
            .succeeded(id: custom.id, at: now),
            .started(id: dev.id, position: 2, total: 2), .succeeded(id: dev.id, at: now),
            .finished,
        ])
    }

    @Test func customLoginWithoutCommandWaitsWithoutTerminal() async throws {
        let directory = try makeCLIDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let terminal = FakeTerminal()
        let queue = makeQueue(runner: succeedingRunner(), terminal: terminal, path: directory)
        var events = EventReader(queue)
        let custom = customLogin(command: nil)

        await queue.enqueue([custom], timeout: timeout)

        #expect(await events.next(3) == [
            .queued(ids: [custom.id], total: 1),
            .started(id: custom.id, position: 1, total: 1), .waitingForDone(id: custom.id),
        ])
        #expect(terminal.commands.isEmpty)
        await queue.confirmCustomDone(id: custom.id)
        #expect(await events.throughFinished() == [.succeeded(id: custom.id, at: now), .finished])
    }

    @Test func customLoginTimesOutWithoutDone() async throws {
        let directory = try makeCLIDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = makeQueue(runner: succeedingRunner(), path: directory)
        var events = EventReader(queue)
        let custom = customLogin(command: "az login")

        await queue.enqueue([custom], timeout: shortTimeout)

        #expect(await events.throughFinished() == [
            .queued(ids: [custom.id], total: 1),
            .started(id: custom.id, position: 1, total: 1), .waitingForDone(id: custom.id),
            .failed(id: custom.id, reason: .timedOut), .finished,
        ])
    }

    @Test func terminalFailureIsReported() async throws {
        let directory = try makeCLIDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let terminal = FakeTerminal(failure: TerminalNotStarted())
        let queue = makeQueue(runner: succeedingRunner(), terminal: terminal, path: directory)
        var events = EventReader(queue)
        let custom = customLogin(command: "az login")

        await queue.enqueue([custom], timeout: timeout)

        #expect(await events.throughFinished() == [
            .queued(ids: [custom.id], total: 1),
            .started(id: custom.id, position: 1, total: 1),
            .failed(id: custom.id, reason: .terminalFailed("Terminal couldn't be started")),
            .finished,
        ])
    }

    @Test func aDeniedTerminalPermissionIsItsOwnFailure() async throws {
        let directory = try makeCLIDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let terminal = FakeTerminal(failure: TerminalNotPermitted())
        let queue = makeQueue(runner: succeedingRunner(), terminal: terminal, path: directory)
        var events = EventReader(queue)
        let custom = customLogin(command: "az login")

        await queue.enqueue([custom], timeout: timeout)

        #expect(await events.throughFinished() == [
            .queued(ids: [custom.id], total: 1),
            .started(id: custom.id, position: 1, total: 1),
            .failed(id: custom.id, reason: .terminalNotPermitted),
            .finished,
        ])
    }

    @Test func cancelEndsRunningAndDropsRemaining() async throws {
        let directory = try makeCLIDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entered = Gate()
        let runner = FakeRunner { index in
            guard index == 0 else { return .exited(code: 0, output: "") }
            await entered.open()
            await waitUntilCancelled()
            return .cancelled
        }
        let queue = makeQueue(runner: runner, path: directory)
        var events = EventReader(queue)
        let dev = awsLogin("dev")
        let prod = awsLogin("prod")
        let analytics = databricksLogin("analytics-dev")

        await queue.enqueue([dev, prod, analytics], timeout: timeout)
        await entered.wait()
        await queue.cancel()

        #expect(await events.throughFinished() == [
            .queued(ids: [dev.id, prod.id, analytics.id], total: 3), .started(id: dev.id, position: 1, total: 3),
            .queued(ids: [], total: 1), .failed(id: dev.id, reason: .cancelled), .finished,
        ])
        let later = awsLogin("later")
        await queue.enqueue([later], timeout: timeout)
        #expect(await events.throughFinished() == [
            .queued(ids: [later.id], total: 1),
            .started(id: later.id, position: 1, total: 1), .succeeded(id: later.id, at: now), .finished,
        ])
        #expect(runner.calls.map(\.arguments) == [
            ["sso", "login", "--sso-session=dev"], ["sso", "login", "--sso-session=later"],
        ])
    }

    @Test func cancelWhenIdleEmitsNothing() async throws {
        let directory = try makeCLIDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = makeQueue(runner: succeedingRunner(), path: directory)
        var events = EventReader(queue)
        let dev = awsLogin("dev")
        let prod = awsLogin("prod")

        await queue.cancel()
        await queue.enqueue([dev], timeout: timeout)
        #expect(await events.throughFinished() == [
            .queued(ids: [dev.id], total: 1),
            .started(id: dev.id, position: 1, total: 1), .succeeded(id: dev.id, at: now), .finished,
        ])
        await queue.cancel()
        await queue.enqueue([prod], timeout: timeout)
        #expect(await events.throughFinished() == [
            .queued(ids: [prod.id], total: 1),
            .started(id: prod.id, position: 1, total: 1), .succeeded(id: prod.id, at: now), .finished,
        ])
    }

    @Test func cancelDuringPathResolveIsCancelled() async throws {
        let emptyDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: emptyDirectory) }
        let entered = Gate()
        let release = Gate()
        let shell = FakeRunner { _ in
            await entered.open()
            await release.wait()
            return pathOutput(emptyDirectory.path)
        }
        let resolver = ShellPathResolver(runner: shell, shell: zsh, environment: [:])
        let runner = succeedingRunner()
        let queue = LoginQueue(runner: runner, pathResolver: resolver, terminal: FakeTerminal(), clock: { now })
        var events = EventReader(queue)
        let dev = awsLogin("dev")

        await queue.enqueue([dev], timeout: timeout)
        await entered.wait()
        await queue.cancel()
        await release.open()

        #expect(await events.throughFinished() == [
            .queued(ids: [dev.id], total: 1),
            .started(id: dev.id, position: 1, total: 1), .failed(id: dev.id, reason: .cancelled), .finished,
        ])
        #expect(runner.calls.isEmpty)
    }

    @Test func enqueueRightAfterCancelStartsNewRun() async throws {
        let directory = try makeCLIDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entered = Gate()
        let stopped = Gate()
        let runner = FakeRunner { index in
            guard index == 0 else { return .exited(code: 0, output: "") }
            await entered.open()
            await waitUntilCancelled()
            await stopped.wait()
            return .cancelled
        }
        let queue = makeQueue(runner: runner, path: directory)
        var events = EventReader(queue)
        let dev = awsLogin("dev")

        await queue.enqueue([dev], timeout: timeout)
        await entered.wait()
        await queue.cancel()
        await queue.enqueue([dev], timeout: timeout)
        await stopped.open()

        #expect(await events.throughFinished() == [
            .queued(ids: [dev.id], total: 1), .started(id: dev.id, position: 1, total: 1),
            .queued(ids: [dev.id], total: 1), .failed(id: dev.id, reason: .cancelled), .finished,
        ])
        #expect(await events.throughFinished() == [
            .started(id: dev.id, position: 1, total: 1), .succeeded(id: dev.id, at: now), .finished,
        ])
        #expect(runner.calls.count == 2)
    }

    @Test func cancelWhileWaitingForDoneEnds() async throws {
        let directory = try makeCLIDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = succeedingRunner()
        let queue = makeQueue(runner: runner, path: directory)
        var events = EventReader(queue)
        let custom = customLogin(command: nil)
        let dev = awsLogin("dev")

        await queue.enqueue([custom, dev], timeout: timeout)
        #expect(await events.next(3) == [
            .queued(ids: [custom.id, dev.id], total: 2),
            .started(id: custom.id, position: 1, total: 2), .waitingForDone(id: custom.id),
        ])
        await queue.cancel()

        #expect(await events.throughFinished() == [
            .queued(ids: [], total: 1), .failed(id: custom.id, reason: .cancelled), .finished,
        ])
        #expect(runner.calls.isEmpty)
    }

    @Test func cancelWhileOpeningTerminalIsCancelled() async throws {
        let directory = try makeCLIDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entered = Gate()
        let release = Gate()
        let terminal = FakeTerminal(hold: (entered, release))
        let queue = makeQueue(runner: succeedingRunner(), terminal: terminal, path: directory)
        var events = EventReader(queue)
        let custom = customLogin(command: "az login")

        await queue.enqueue([custom], timeout: timeout)
        await entered.wait()
        await queue.cancel()
        await release.open()

        #expect(await events.throughFinished() == [
            .queued(ids: [custom.id], total: 1),
            .started(id: custom.id, position: 1, total: 1), .failed(id: custom.id, reason: .cancelled), .finished,
        ])
    }

    @Test func aTerminalThatNeverAnswersTimesOut() async throws {
        let directory = try makeCLIDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let release = Gate()
        let terminal = FakeTerminal(hold: (Gate(), release))
        let queue = makeQueue(runner: succeedingRunner(), terminal: terminal, path: directory)
        var events = EventReader(queue)
        let custom = customLogin(command: "az login")
        let dev = awsLogin("dev")

        await queue.enqueue([custom, dev], timeout: shortTimeout)

        #expect(await events.throughFinished() == [
            .queued(ids: [custom.id, dev.id], total: 2), .started(id: custom.id, position: 1, total: 2),
            .failed(id: custom.id, reason: .timedOut),
            .started(id: dev.id, position: 2, total: 2), .succeeded(id: dev.id, at: now), .finished,
        ])
        await release.open()
    }

    @Test func cancelEndsATerminalThatNeverAnswers() async throws {
        let directory = try makeCLIDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entered = Gate()
        let release = Gate()
        let terminal = FakeTerminal(hold: (entered, release))
        let queue = makeQueue(runner: succeedingRunner(), terminal: terminal, path: directory)
        var events = EventReader(queue)
        let custom = customLogin(command: "az login")

        await queue.enqueue([custom], timeout: timeout)
        await entered.wait()
        await queue.cancel()

        #expect(await events.throughFinished() == [
            .queued(ids: [custom.id], total: 1),
            .started(id: custom.id, position: 1, total: 1), .failed(id: custom.id, reason: .cancelled), .finished,
        ])
        await release.open()
    }

    @Test func oneTimeoutCoversOpeningTerminalAndTheWaitForDone() async throws {
        let directory = try makeCLIDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let release = Gate()
        let terminal = FakeTerminal(hold: (Gate(), release))
        let queue = makeQueue(runner: succeedingRunner(), terminal: terminal, path: directory)
        var events = EventReader(queue)
        let custom = customLogin(command: "az login")
        let started = ContinuousClock.now

        await queue.enqueue([custom], timeout: 3)
        try await Task.sleep(for: .milliseconds(1500))
        await release.open()

        #expect(await events.throughFinished() == [
            .queued(ids: [custom.id], total: 1), .started(id: custom.id, position: 1, total: 1),
            .waitingForDone(id: custom.id), .failed(id: custom.id, reason: .timedOut), .finished,
        ])
        // A wait for Done that restarted the timeout after the open would end near 4.5 s.
        #expect(ContinuousClock.now - started < .milliseconds(3750))
    }

    @Test func anAbandonedOpenIsCancelled() async throws {
        let directory = try makeCLIDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let terminal = CancelWaitingTerminal()
        let queue = makeQueue(runner: succeedingRunner(), terminal: terminal, path: directory)
        var events = EventReader(queue)
        let custom = customLogin(command: "az login")

        await queue.enqueue([custom], timeout: shortTimeout)
        _ = await events.throughFinished()

        for _ in 0..<50 where !terminal.sawCancel {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(terminal.sawCancel)
    }

    @Test func removingAQueuedLoginShrinksTheTotal() async throws {
        let directory = try makeCLIDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entered = Gate()
        let release = Gate()
        let runner = FakeRunner { index in
            if index == 0 {
                await entered.open()
                await release.wait()
            }
            return .exited(code: 0, output: "")
        }
        let queue = makeQueue(runner: runner, path: directory)
        var events = EventReader(queue)
        let dev = awsLogin("dev")
        let prod = awsLogin("prod")
        let analytics = databricksLogin("analytics-dev")

        await queue.enqueue([dev, prod, analytics], timeout: timeout)
        await entered.wait()
        await queue.remove(id: prod.id)
        await release.open()

        #expect(await events.throughFinished() == [
            .queued(ids: [dev.id, prod.id, analytics.id], total: 3), .started(id: dev.id, position: 1, total: 3),
            .queued(ids: [analytics.id], total: 2), .succeeded(id: dev.id, at: now),
            .started(id: analytics.id, position: 2, total: 2), .succeeded(id: analytics.id, at: now),
            .finished,
        ])
        #expect(runner.calls.map(\.arguments) == [
            ["sso", "login", "--sso-session=dev"], ["auth", "login", "--profile=analytics-dev"],
        ])
    }

    @Test func removingTheRunningLoginCancelsItAndGoesOn() async throws {
        let directory = try makeCLIDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entered = Gate()
        let runner = FakeRunner { index in
            guard index == 0 else { return .exited(code: 0, output: "") }
            await entered.open()
            await waitUntilCancelled()
            return .cancelled
        }
        let queue = makeQueue(runner: runner, path: directory)
        var events = EventReader(queue)
        let dev = awsLogin("dev")
        let prod = awsLogin("prod")

        await queue.enqueue([dev, prod], timeout: timeout)
        await entered.wait()
        await queue.remove(id: dev.id)

        #expect(await events.throughFinished() == [
            .queued(ids: [dev.id, prod.id], total: 2),
            .started(id: dev.id, position: 1, total: 2), .failed(id: dev.id, reason: .cancelled),
            .started(id: prod.id, position: 2, total: 2), .succeeded(id: prod.id, at: now),
            .finished,
        ])
    }

    @Test func removingTheLoginWaitingForDoneGoesOn() async throws {
        let directory = try makeCLIDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = makeQueue(runner: succeedingRunner(), path: directory)
        var events = EventReader(queue)
        let custom = customLogin(command: nil)
        let dev = awsLogin("dev")

        await queue.enqueue([custom, dev], timeout: timeout)
        #expect(await events.next(3) == [
            .queued(ids: [custom.id, dev.id], total: 2),
            .started(id: custom.id, position: 1, total: 2), .waitingForDone(id: custom.id),
        ])
        await queue.remove(id: custom.id)

        #expect(await events.throughFinished() == [
            .failed(id: custom.id, reason: .cancelled),
            .started(id: dev.id, position: 2, total: 2), .succeeded(id: dev.id, at: now),
            .finished,
        ])
    }

    @Test func aRemovedRunningLoginCanBeQueuedAgain() async throws {
        let directory = try makeCLIDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entered = Gate()
        let stopped = Gate()
        let runner = FakeRunner { index in
            guard index == 0 else { return .exited(code: 0, output: "") }
            await entered.open()
            await waitUntilCancelled()
            await stopped.wait()
            return .cancelled
        }
        let queue = makeQueue(runner: runner, path: directory)
        var events = EventReader(queue)
        let dev = awsLogin("dev")

        await queue.enqueue([dev], timeout: timeout)
        await entered.wait()
        await queue.remove(id: dev.id)
        await queue.enqueue([dev], timeout: timeout)
        await stopped.open()

        #expect(await events.throughFinished() == [
            .queued(ids: [dev.id], total: 1), .started(id: dev.id, position: 1, total: 1),
            .queued(ids: [dev.id], total: 2), .failed(id: dev.id, reason: .cancelled),
            .started(id: dev.id, position: 2, total: 2), .succeeded(id: dev.id, at: now),
            .finished,
        ])
    }

    @Test func removingAnUnknownLoginDoesNothing() async throws {
        let directory = try makeCLIDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entered = Gate()
        let release = Gate()
        let runner = FakeRunner { index in
            if index == 0 {
                await entered.open()
                await release.wait()
            }
            return .exited(code: 0, output: "")
        }
        let queue = makeQueue(runner: runner, path: directory)
        var events = EventReader(queue)
        let dev = awsLogin("dev")
        let prod = awsLogin("prod")

        await queue.remove(id: dev.id)
        await queue.enqueue([dev, prod], timeout: timeout)
        await entered.wait()
        await queue.remove(id: UUID())
        await release.open()

        #expect(await events.throughFinished() == [
            .queued(ids: [dev.id, prod.id], total: 2),
            .started(id: dev.id, position: 1, total: 2), .succeeded(id: dev.id, at: now),
            .started(id: prod.id, position: 2, total: 2), .succeeded(id: prod.id, at: now),
            .finished,
        ])
    }

    @Test func removingTheRunningLoginAfterCancelAllStillEndsTheRun() async throws {
        let directory = try makeCLIDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entered = Gate()
        let runner = FakeRunner { index in
            guard index == 0 else { return .exited(code: 0, output: "") }
            await entered.open()
            await waitUntilCancelled()
            return .cancelled
        }
        let queue = makeQueue(runner: runner, path: directory)
        var events = EventReader(queue)
        let dev = awsLogin("dev")
        let prod = awsLogin("prod")
        let later = awsLogin("later")

        await queue.enqueue([dev, prod], timeout: timeout)
        await entered.wait()
        await queue.cancel()
        await queue.remove(id: dev.id)
        let cancelledRun = await events.throughFinished()
        await queue.enqueue([later], timeout: timeout)
        let nextRun = await events.throughFinished()

        #expect(cancelledRun.contains(.failed(id: dev.id, reason: .cancelled)))
        #expect(!cancelledRun.contains { if case .started(prod.id, _, _) = $0 { true } else { false } })
        #expect(nextRun.contains(.started(id: later.id, position: 1, total: 1)))
        #expect(runner.calls.count == 2)
    }

    @Test func eventsEndWhenQueueIsReleased() async throws {
        let directory = try makeCLIDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var queue: LoginQueue? = makeQueue(runner: succeedingRunner(), path: directory)
        var events = try #require(queue.map(EventReader.init))

        queue = nil

        #expect(await events.next(1).isEmpty)
    }

    @Test func lateDoneIsIgnored() async throws {
        let directory = try makeCLIDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = makeQueue(runner: succeedingRunner(), path: directory)
        var events = EventReader(queue)
        let custom = customLogin(command: nil)
        let dev = awsLogin("dev")

        await queue.enqueue([custom], timeout: shortTimeout)
        #expect(await events.throughFinished() == [
            .queued(ids: [custom.id], total: 1),
            .started(id: custom.id, position: 1, total: 1), .waitingForDone(id: custom.id),
            .failed(id: custom.id, reason: .timedOut), .finished,
        ])
        await queue.confirmCustomDone(id: custom.id)
        await queue.enqueue([dev], timeout: timeout)

        #expect(await events.throughFinished() == [
            .queued(ids: [dev.id], total: 1),
            .started(id: dev.id, position: 1, total: 1), .succeeded(id: dev.id, at: now), .finished,
        ])
    }
}

@Test func failureMessagesSayWhatWentWrong() {
    #expect(LoginFailure.cliNotFound("aws").message == "aws not found on your login shell's PATH")
    #expect(LoginFailure.exitCode(2).message == "The login exited with status 2")
    #expect(LoginFailure.signal(9).message == "The login was stopped by signal 9")
    #expect(LoginFailure.timedOut.message == "The login timed out")
    #expect(LoginFailure.cancelled.message == "Cancelled")
    #expect(LoginFailure.launchFailed("aws: permission denied").message == "aws: permission denied")
    #expect(LoginFailure.terminalFailed("Terminal couldn't be started").message == "Terminal couldn't be started")
    #expect(LoginFailure.terminalNotPermitted.message
        == "Allow PrinceClockIn to control Terminal in System Settings → Privacy & Security → Automation")
}
