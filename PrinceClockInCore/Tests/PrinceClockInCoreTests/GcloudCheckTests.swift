import Foundation
import Testing
import PrinceClockInCore

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Date

    init(_ start: Date) { now = start }

    func advance(by interval: TimeInterval) { lock.withLock { now = now.addingTimeInterval(interval) } }
    func read() -> Date { lock.withLock { now } }
}

/// A checker whose `gcloud` is found in a temporary directory and whose runs `respond` answers.
private func makeChecker(
    clock: TestClock = TestClock(at("2026-11-17T09:00:00Z")),
    respond: @escaping @Sendable (Int) async -> ProcessOutcome
) throws -> (GcloudChecker, FakeRunner) {
    let bin = try makeTemporaryDirectory()
    try makeExecutable(named: "gcloud", in: bin)
    let shellRunner = FakeRunner { _ in pathOutput(bin.path) }
    let resolver = ShellPathResolver(runner: shellRunner, shell: URL(fileURLWithPath: "/bin/zsh"), environment: [:])
    let runner = FakeRunner(respond: respond)
    return (GcloudChecker(runner: runner, pathResolver: resolver, clock: { clock.read() }), runner)
}

/// Fixtures in the shape gcloud 594.0.0 builds them: `TokenRefreshError` wraps every refresh failure
/// in "There was a problem refreshing…" and the advice to run `gcloud auth login`.
private func refreshError(_ cause: String) -> ProcessOutcome {
    .exited(
        code: 1,
        output: "ERROR: (gcloud.auth.print-access-token) There was a problem refreshing auth tokens for account "
            + "dev@example.com: \(cause)\nPlease run:\n\n  $ gcloud auth login\n\nto obtain new credentials.\n")
}
private let reauthRequired = refreshError("Reauthentication failed. cannot prompt during non-interactive execution.")
private let refreshRefused = refreshError("('invalid_grant: Token has been expired or revoked.', {'error': 'invalid_grant'})")
private let reauthNeeded = ProcessOutcome.exited(
    code: 1,
    output: "ERROR: (gcloud.auth.print-access-token) There was a problem reauthenticating while refreshing your "
        + "current auth tokens: reauth is required.\nPlease retry your command or run:\n\n  $ gcloud auth login\n")
private let webLoginRequired = ProcessOutcome.exited(
    code: 1,
    output: "ERROR: (gcloud.auth.print-access-token) Please run:\n\n  $ gcloud auth login\n\nto complete reauthentication.\n")
private let noCredentials = ProcessOutcome.exited(
    code: 1,
    output: "ERROR: (gcloud.auth.print-access-token) Your current active account [dev@example.com] does not have any "
        + "valid credentials\nPlease run:\n\n  $ gcloud auth login\n\nto obtain new credentials.\n")

@Suite struct GcloudCheckTests {
    @Test func exitZeroIsValidAndPrintsNoToken() async throws {
        let (checker, runner) = try makeChecker { _ in .exited(code: 0, output: "") }

        #expect(await checker.check(account: "dev@example.com#example.goog", loginRunning: false) == .valid)

        let call = try #require(runner.calls.first)
        #expect(call.arguments == ["auth", "print-access-token", "--account=dev@example.com", "--format=none"])
        #expect(call.discardsStandardOutput)
        #expect(call.timeout == .seconds(30))
    }

    @Test func gcloudsNoCredentialsErrorsAreInvalid() async throws {
        for outcome in [reauthRequired, refreshRefused, reauthNeeded, webLoginRequired, noCredentials] {
            let (checker, _) = try makeChecker { _ in outcome }
            #expect(await checker.check(account: "dev@example.com", loginRunning: false) == .invalid, "\(outcome)")
        }
    }

    @Test func anyOtherFailureIsCouldntCheck() async throws {
        let failures: [ProcessOutcome] = [
            .exited(code: 1, output: "ERROR: gcloud crashed (TransportError): HTTPSConnectionPool(host='oauth2.example.com')"),
            refreshError("temporarily_unavailable: The service is currently unavailable."),
            refreshError("server_error: Internal error."),
            refreshError("('access_denied: Account restricted', {'error': 'access_denied'})"),
            .exited(code: 1, output: "ERROR: (gcloud.auth.print-access-token) You do not currently have an active "
                + "account selected.\nPlease run:\n\n  $ gcloud auth login\n\nto obtain new credentials.\n"),
            .exited(code: 1, output: ""),
            .timedOut(output: ""),
            .cancelled,
            .launchFailed("gcloud: not permitted"),
        ]
        for failure in failures {
            let (checker, _) = try makeChecker { _ in failure }
            #expect(await checker.check(account: "dev@example.com", loginRunning: false) == .couldntCheck, "\(failure)")
        }
    }

    @Test func skipsWithinTheIntervalAndWhileALoginRuns() async throws {
        let clock = TestClock(at("2026-11-17T09:00:00Z"))
        let (checker, runner) = try makeChecker(clock: clock) { _ in .exited(code: 0, output: "") }

        #expect(await checker.check(account: "dev@example.com", loginRunning: true) == .skipped)
        #expect(await checker.check(account: "dev@example.com", loginRunning: false) == .valid)
        clock.advance(by: 299)
        #expect(await checker.check(account: "dev@example.com", loginRunning: false) == .skipped)
        clock.advance(by: 1)
        #expect(await checker.check(account: "dev@example.com", loginRunning: false) == .valid)
        #expect(runner.calls.count == 2)
    }

    @Test func aStoredAnswerHoldsTheIntervalAcrossLaunches() async throws {
        let clock = TestClock(at("2026-11-17T09:00:00Z"))
        let (checker, runner) = try makeChecker(clock: clock) { _ in .exited(code: 0, output: "") }
        let answeredAt = at("2026-11-17T08:55:01Z")

        #expect(await checker.check(account: "dev@example.com", loginRunning: false, lastAnswerAt: answeredAt) == .skipped)
        #expect(runner.calls.isEmpty)
        clock.advance(by: 1)
        #expect(await checker.check(account: "dev@example.com", loginRunning: false, lastAnswerAt: answeredAt) == .valid)
        #expect(runner.calls.count == 1)
    }

    @Test func aCheckThatDidntRunTheCLILeavesTheIntervalFree() async throws {
        let (checker, runner) = try makeChecker { index in
            index == 0 ? .launchFailed("gcloud: not permitted") : .exited(code: 0, output: "")
        }

        _ = await checker.check(account: "dev@example.com", loginRunning: false)

        #expect(await checker.check(account: "dev@example.com", loginRunning: false) == .valid)
        #expect(runner.calls.count == 2)
    }

    @Test func gcloudNotOnPathIsCouldntCheck() async {
        let shellRunner = FakeRunner { _ in pathOutput("/nonexistent-dir") }
        let resolver = ShellPathResolver(runner: shellRunner, shell: URL(fileURLWithPath: "/bin/zsh"), environment: [:])
        let runner = FakeRunner { _ in .exited(code: 0, output: "") }
        let checker = GcloudChecker(runner: runner, pathResolver: resolver)

        #expect(await checker.check(account: "dev@example.com", loginRunning: false) == .couldntCheck)
        #expect(runner.calls.isEmpty)
    }
}
