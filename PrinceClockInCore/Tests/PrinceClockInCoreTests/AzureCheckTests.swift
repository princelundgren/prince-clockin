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

private let tenant = "00000000-0000-0000-0000-000000000001"
private let dev = AzureAccount(user: "dev@example.com", tenant: tenant)
private let ops = AzureAccount(user: "ops@example.com", tenant: tenant)

/// An `azureProfile.json` that always reads as `profile`.
private struct FixedAzureProfile: AzureProfileReading {
    let profile: AzureProfile?

    func read() -> AzureProfile? { profile }
}

/// A profile listing `accounts`, with the subscription of `defaultUser`, if any, the default.
private func profile(_ accounts: [AzureAccount], defaultUser: String?) -> FixedAzureProfile {
    FixedAzureProfile(profile: AzureProfile(
        subscriptions: accounts.map { AzureSubscription(account: $0, isDefault: $0.user == defaultUser) },
        modified: nil))
}

/// A checker whose `az` is found in a temporary directory and whose runs `respond` answers; by
/// default, the profile makes `dev`'s subscription the default.
private func makeChecker(
    clock: TestClock = TestClock(at("2026-11-17T09:00:00Z")),
    profile: AzureProfileReading = profile([dev, ops], defaultUser: dev.user),
    respond: @escaping @Sendable (Int) async -> ProcessOutcome
) throws -> (AzureChecker, FakeRunner) {
    let bin = try makeTemporaryDirectory()
    try makeExecutable(named: "az", in: bin)
    let shellRunner = FakeRunner { _ in pathOutput(bin.path) }
    let resolver = ShellPathResolver(runner: shellRunner, shell: URL(fileURLWithPath: "/bin/zsh"), environment: [:])
    let runner = FakeRunner(respond: respond)
    return (AzureChecker(runner: runner, pathResolver: resolver, profile: profile, clock: { clock.read() }), runner)
}

/// An Entra error as azure-cli 2.93.0 reports it: the server's description, then the advice to run
/// `az login` that it gives every Entra error.
private func entraError(_ description: String) -> ProcessOutcome {
    .exited(
        code: 1,
        output: "ERROR: \(description)\nTrace ID: 44444444-4444-4444-4444-444444444444\n"
            + "Run the command below to authenticate interactively; additional arguments may be added as needed:\n"
            + "az login --tenant \"\(tenant)\" --scope \"https://management.core.windows.net//.default\"\n")
}

private let noTokenInCache = ProcessOutcome.exited(
    code: 1, output: "ERROR: Can't find token from MSAL cache.\nTo re-authenticate, please run:\naz login\n")
private let noUserInCache = ProcessOutcome.exited(
    code: 1, output: "ERROR: User 'dev@example.com' does not exist in MSAL token cache. Run `az login`.\n")
private let signInAgainCodes = [
    "AADSTS50173: The provided grant has expired due to it being revoked, a fresh auth token is needed.",
    "AADSTS70008: The provided authorization code or refresh token has expired due to inactivity.",
    "AADSTS700082: The refresh token has expired due to inactivity.",
    "AADSTS70043: The refresh token has expired or is invalid due to sign-in frequency checks by conditional access.",
    "AADSTS50078: Presented multi-factor authentication has expired due to policies configured by your administrator.",
    "AADSTS50076: Due to a configuration change made by your administrator, you must use multi-factor authentication.",
    "AADSTS50079: Due to a configuration change made by your administrator, you are required to enroll in MFA.",
    "AADSTS50132: The session isn't valid due to password expiration or recent password change.",
    "AADSTS50133: The session isn't valid due to password expiration or recent password change.",
]

@Suite struct AzureCheckTests {
    @Test func exitZeroIsValidAndPrintsNoToken() async throws {
        let (checker, runner) = try makeChecker { _ in .exited(code: 0, output: "") }

        #expect(await checker.check(account: dev, loginRunning: false) == .valid)

        let call = try #require(runner.calls.first)
        #expect(call.executable.lastPathComponent == "az")
        #expect(call.arguments == ["account", "get-access-token", "--tenant=\(tenant)", "--output=none"])
        #expect(call.discardsStandardOutput)
        #expect(call.timeout == .seconds(30))
    }

    @Test func aStoredAnswerHoldsTheIntervalAcrossLaunches() async throws {
        let clock = TestClock(at("2026-11-17T09:00:00Z"))
        let (checker, runner) = try makeChecker(clock: clock) { _ in .exited(code: 0, output: "") }
        let answeredAt = at("2026-11-17T08:55:01Z")

        #expect(await checker.check(account: dev, loginRunning: false, lastAnswerAt: answeredAt) == .skipped)
        #expect(runner.calls.isEmpty)
        clock.advance(by: 1)
        #expect(await checker.check(account: dev, loginRunning: false, lastAnswerAt: answeredAt) == .valid)
        #expect(runner.calls.count == 1)
    }

    @Test func theTrackedUserActiveRunsTheCheck() async throws {
        let differentCase = AzureAccount(user: "Dev@Example.com", tenant: tenant)
        let (checker, runner) = try makeChecker(profile: profile([ops, differentCase], defaultUser: differentCase.user)) { _ in
            .exited(code: 0, output: "")
        }

        #expect(await checker.check(account: dev, loginRunning: false) == .valid)
        #expect(runner.calls.count == 1)
    }

    @Test func anotherUserActiveSkipsWithoutRunningAz() async throws {
        let (checker, runner) = try makeChecker(profile: profile([dev, ops], defaultUser: ops.user)) { _ in
            .exited(code: 0, output: "")
        }

        #expect(await checker.check(account: dev, loginRunning: false) == .skipped)
        #expect(runner.calls.isEmpty)
    }

    @Test func noDefaultSubscriptionSkipsWithoutRunningAz() async throws {
        let profiles: [AzureProfileReading] = [
            profile([dev], defaultUser: nil), FixedAzureProfile(profile: .none), FixedAzureProfile(profile: nil),
        ]
        for unknown in profiles {
            let (checker, runner) = try makeChecker(profile: unknown) { _ in .exited(code: 0, output: "") }

            #expect(await checker.check(account: dev, loginRunning: false) == .skipped, "\(unknown)")
            #expect(runner.calls.isEmpty)
        }
    }

    @Test func noTokenOrUserInTheMSALCacheIsInvalid() async throws {
        for outcome in [noTokenInCache, noUserInCache] {
            let (checker, _) = try makeChecker { _ in outcome }
            #expect(await checker.check(account: dev, loginRunning: false) == .invalid, "\(outcome)")
        }
    }

    @Test func anEntraCodeThatNeedsASignInIsInvalid() async throws {
        for description in signInAgainCodes {
            let (checker, _) = try makeChecker { _ in entraError(description) }
            #expect(await checker.check(account: dev, loginRunning: false) == .invalid, "\(description)")
        }
    }

    @Test func aCodeIsFoundAfterALongerCodeThatStartsTheSame() async throws {
        let (checker, _) = try makeChecker { _ in
            entraError("AADSTS700084: The refresh token has a fixed lifetime. Caused by AADSTS70008.")
        }

        #expect(await checker.check(account: dev, loginRunning: false) == .invalid)
    }

    @Test func anyOtherFailureIsCouldntCheck() async throws {
        let failures: [ProcessOutcome] = [
            entraError("AADSTS90033: A transient error has occurred. Please try again."),
            entraError("(temporarily_unavailable) The service is temporarily unavailable."),
            entraError("AADSTS700084: The refresh token was issued to a single page app, and has a fixed lifetime."),
            entraError("AADSTS500011: The resource principal named https://example.com was not found in the tenant."),
            .exited(code: 1, output: "ERROR: HTTPSConnectionPool(host='login.microsoftonline.com', port=443): Max "
                + "retries exceeded with url: /organizations/oauth2/v2.0/token (Caused by NewConnectionError)\n"),
            .exited(code: 1, output: "ERROR: Please run 'az login' to setup account.\n"),
            .exited(code: 1, output: ""),
            .timedOut(output: ""),
            .cancelled,
            .launchFailed("az: not permitted"),
        ]
        for failure in failures {
            let (checker, _) = try makeChecker { _ in failure }
            #expect(await checker.check(account: dev, loginRunning: false) == .couldntCheck, "\(failure)")
        }
    }

    @Test func skipsWithinTheIntervalAndWhileALoginRuns() async throws {
        let clock = TestClock(at("2026-11-17T09:00:00Z"))
        let (checker, runner) = try makeChecker(clock: clock) { _ in .exited(code: 0, output: "") }

        #expect(await checker.check(account: dev, loginRunning: true) == .skipped)
        #expect(await checker.check(account: dev, loginRunning: false) == .valid)
        clock.advance(by: 299)
        #expect(await checker.check(account: dev, loginRunning: false) == .skipped)
        clock.advance(by: 1)
        #expect(await checker.check(account: dev, loginRunning: false) == .valid)
        #expect(runner.calls.count == 2)
    }

    @Test func aCheckThatDidntRunTheCLILeavesTheIntervalFree() async throws {
        let (checker, runner) = try makeChecker { index in
            index == 0 ? .launchFailed("az: not permitted") : .exited(code: 0, output: "")
        }

        _ = await checker.check(account: dev, loginRunning: false)

        #expect(await checker.check(account: dev, loginRunning: false) == .valid)
        #expect(runner.calls.count == 2)
    }

    @Test func azNotOnPathIsCouldntCheck() async {
        let shellRunner = FakeRunner { _ in pathOutput("/nonexistent-dir") }
        let resolver = ShellPathResolver(runner: shellRunner, shell: URL(fileURLWithPath: "/bin/zsh"), environment: [:])
        let runner = FakeRunner { _ in .exited(code: 0, output: "") }
        let checker = AzureChecker(runner: runner, pathResolver: resolver, profile: profile([dev], defaultUser: dev.user))

        #expect(await checker.check(account: dev, loginRunning: false) == .couldntCheck)
        #expect(runner.calls.isEmpty)
    }
}
