import Foundation
import Testing
import PrinceClockInCore

private let recordedAuthError = ProcessOutcome.exited(
    code: 1, output: "Error: error getting token: cache: no cached credentials; run `databricks auth login` to sign in\n")

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Date

    init(_ start: Date) { now = start }

    func advance(by interval: TimeInterval) { lock.withLock { now = now.addingTimeInterval(interval) } }
    func read() -> Date { lock.withLock { now } }
}

/// A resolver that answers `path` and counts how often it was asked.
private final class CountingResolver: PathResolving, @unchecked Sendable {
    private let lock = NSLock()
    private let path: ResolvedPath
    private var calls = 0

    init(_ path: ResolvedPath) { self.path = path }

    var count: Int { lock.withLock { calls } }

    func resolvePath() async -> ResolvedPath {
        lock.withLock { calls += 1 }
        return path
    }
}

/// A checker whose `databricks` is found in a temporary directory and whose runs `respond` answers.
private func makeChecker(
    clock: TestClock = TestClock(at("2026-11-17T09:00:00Z")),
    respond: @escaping @Sendable (Int) async -> ProcessOutcome
) throws -> (DatabricksChecker, FakeRunner) {
    let bin = try makeTemporaryDirectory()
    try makeExecutable(named: "databricks", in: bin)
    let shellRunner = FakeRunner { _ in pathOutput(bin.path) }
    let resolver = ShellPathResolver(runner: shellRunner, shell: URL(fileURLWithPath: "/bin/zsh"), environment: [:])
    let runner = FakeRunner(respond: respond)
    return (DatabricksChecker(runner: runner, pathResolver: resolver, clock: { clock.read() }), runner)
}

@Suite struct DatabricksCheckTests {
    @Test func databricksExitZeroIsValid() async throws {
        let (checker, runner) = try makeChecker { _ in .exited(code: 0, output: "") }
        #expect(await checker.check(profile: "dev", accountLevel: false, loginRunning: false) == .valid)
        #expect(runner.calls[0].arguments == ["current-user", "me", "--profile=dev"])
        #expect(runner.calls[0].timeout == .seconds(30))
    }

    @Test func aProfileNameStartingWithADashStaysJoinedToItsFlag() async throws {
        let (checker, runner) = try makeChecker { _ in .exited(code: 0, output: "") }
        _ = await checker.check(profile: "-h", accountLevel: false, loginRunning: false)
        #expect(runner.calls[0].arguments == ["current-user", "me", "--profile=-h"])
    }

    @Test func databricksSkipsWithinInterval() async throws {
        let clock = TestClock(at("2026-11-17T09:00:00Z"))
        let (checker, runner) = try makeChecker(clock: clock) { _ in .exited(code: 0, output: "") }
        #expect(await checker.check(profile: "dev", accountLevel: false, loginRunning: false) == .valid)
        clock.advance(by: 299)
        #expect(await checker.check(profile: "dev", accountLevel: false, loginRunning: false) == .skipped)
        #expect(runner.calls.count == 1)
        clock.advance(by: 1)
        #expect(await checker.check(profile: "dev", accountLevel: false, loginRunning: false) == .valid)
        #expect(runner.calls.count == 2)
    }

    @Test func databricksSkipsWhileLoginRunning() async throws {
        let (checker, runner) = try makeChecker { _ in .exited(code: 0, output: "") }
        #expect(await checker.check(profile: "dev", accountLevel: false, loginRunning: true) == .skipped)
        #expect(runner.calls.isEmpty)
    }

    @Test func databricksSkipsAccountLevelProfile() async throws {
        let (checker, runner) = try makeChecker { _ in .exited(code: 0, output: "") }
        #expect(await checker.check(profile: "dev", accountLevel: true, loginRunning: false) == .skipped)
        #expect(runner.calls.isEmpty)
    }

    @Test func databricksRecordedAuthErrorIsInvalid() async throws {
        let (checker, _) = try makeChecker { _ in recordedAuthError }
        #expect(await checker.check(profile: "dev", accountLevel: false, loginRunning: false) == .invalid)
    }

    @Test func databricksOtherFailureIsCouldntCheck() async throws {
        let failures: [ProcessOutcome] = [
            .exited(code: 1, output: "Error: dial tcp: lookup example.cloud.databricks.com: no such host"),
            .exited(code: 1, output: ""),
            .timedOut(output: ""),
            .cancelled,
            .launchFailed("databricks: not permitted"),
        ]
        for failure in failures {
            let (checker, _) = try makeChecker { _ in failure }
            #expect(
                await checker.check(profile: "dev", accountLevel: false, loginRunning: false) == .couldntCheck,
                "\(failure)")
        }
    }

    @Test func aCheckThatRanTheCLIHoldsTheInterval() async throws {
        let ran: [ProcessOutcome] = [.exited(code: 1, output: ""), .timedOut(output: "")]
        for outcome in ran {
            let (checker, runner) = try makeChecker { _ in outcome }
            _ = await checker.check(profile: "dev", accountLevel: false, loginRunning: false)
            #expect(await checker.check(profile: "dev", accountLevel: false, loginRunning: false) == .skipped, "\(outcome)")
            #expect(runner.calls.count == 1, "\(outcome)")
        }
    }

    @Test func aCheckThatDidntRunTheCLILeavesTheIntervalFree() async throws {
        let notRun: [ProcessOutcome] = [.launchFailed("databricks: not permitted"), .cancelled]
        for outcome in notRun {
            let (checker, runner) = try makeChecker { index in index == 0 ? outcome : .exited(code: 0, output: "") }
            _ = await checker.check(profile: "dev", accountLevel: false, loginRunning: false)
            #expect(await checker.check(profile: "dev", accountLevel: false, loginRunning: false) == .valid, "\(outcome)")
            #expect(runner.calls.count == 2, "\(outcome)")
        }
    }

    @Test func databricksAuthErrorWithExitZeroIsStillValid() async throws {
        let (checker, _) = try makeChecker { _ in
            .exited(code: 0, output: "error getting token: cache: no cached credentials")
        }
        #expect(await checker.check(profile: "dev", accountLevel: false, loginRunning: false) == .valid)
    }

    @Test func databricksChecksOneProfileOnly() async throws {
        let (checker, runner) = try makeChecker { _ in .exited(code: 0, output: "") }
        _ = await checker.check(profile: "dev", accountLevel: false, loginRunning: false)
        #expect(runner.calls[0].arguments.filter { $0.hasPrefix("--profile") }.count == 1)
        #expect(runner.calls[0].arguments.contains("token") == false)
    }

    @Test func concurrentChecksOfOneProfileRunOnce() async throws {
        let gate = Gate()
        let (checker, runner) = try makeChecker { _ in
            await gate.wait()
            return .exited(code: 0, output: "")
        }
        async let first = checker.check(profile: "dev", accountLevel: false, loginRunning: false)
        async let second = checker.check(profile: "dev", accountLevel: false, loginRunning: false)
        // Timing assumption: both calls reach the checker before the run is released. If one
        // arrived after the first finished it would be skipped by the interval anyway.
        try await Task.sleep(for: .milliseconds(100))
        await gate.open()
        let results = await [first, second]
        #expect(results.contains(.valid) && results.contains(.skipped))
        #expect(runner.calls.count == 1)
    }

    @Test func aCheckResolvesThePathOnce() async throws {
        let bin = try makeTemporaryDirectory()
        try makeExecutable(named: "databricks", in: bin)
        let resolver = CountingResolver(ResolvedPath(directories: [bin], fromShell: false))
        let runner = FakeRunner { _ in .exited(code: 0, output: "") }
        let checker = DatabricksChecker(runner: runner, pathResolver: resolver)
        #expect(await checker.check(profile: "dev", accountLevel: false, loginRunning: false) == .valid)
        #expect(resolver.count == 1)
        #expect(runner.calls[0].environment["PATH"] == bin.path)
    }

    @Test func databricksNotOnPathIsCouldntCheckAndLeavesTheIntervalFree() async {
        let shellRunner = FakeRunner { _ in pathOutput("/nonexistent-dir") }
        let resolver = ShellPathResolver(runner: shellRunner, shell: URL(fileURLWithPath: "/bin/zsh"), environment: [:])
        let runner = FakeRunner { _ in .exited(code: 0, output: "") }
        let checker = DatabricksChecker(runner: runner, pathResolver: resolver)
        #expect(await checker.check(profile: "dev", accountLevel: false, loginRunning: false) == .couldntCheck)
        #expect(await checker.check(profile: "dev", accountLevel: false, loginRunning: false) == .couldntCheck)
        #expect(runner.calls.isEmpty)
    }
}
