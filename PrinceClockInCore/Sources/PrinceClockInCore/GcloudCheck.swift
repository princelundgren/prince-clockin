import Foundation

/// Asks gcloud whether an account still has a usable login. Runs
/// `gcloud config config-helper --force-auth-refresh --account=<email> --format=none`, which
/// refreshes the token even when gcloud holds an unexpired one, so the answer isn't read from its
/// cache. Its output holds a token: `--format=none` makes gcloud print nothing, and the run's
/// stdout goes to `/dev/null` besides, so no token reaches the app. Its result is a
/// `DatabricksCheck`, which means the same for either CLI.
public actor GcloudChecker {
    /// What gcloud writes to stderr when only a new `gcloud auth login` helps: reauthentication
    /// that failed or is required, a refresh token the server refused as `invalid_grant`, or no
    /// credentials for the account. gcloud wraps every refresh failure, a server outage or rate
    /// limit too, in "There was a problem refreshing…", so that wrapper alone is no answer.
    private static let authFailures = [
        "Reauthentication failed",
        "There was a problem reauthenticating while refreshing",
        "to complete reauthentication",
        "invalid_grant",
        "does not have any valid credentials",
    ]

    private let runner: ProcessRunning
    private let pathResolver: any PathResolving
    private let clock: @Sendable () -> Date
    private let minInterval: TimeInterval
    private let timeout: TimeInterval
    private var lastCheck: [String: Date] = [:]

    public init(
        runner: ProcessRunning, pathResolver: any PathResolving,
        clock: @escaping @Sendable () -> Date = Date.init,
        minInterval: TimeInterval = 300, timeout: TimeInterval = 30
    ) {
        self.runner = runner
        self.pathResolver = pathResolver
        self.clock = clock
        self.minInterval = minInterval
        self.timeout = timeout
    }

    /// `.valid` on exit 0 and `.invalid` on one of gcloud's no-credentials errors; any other
    /// failure is `.couldntCheck`, so an offline failure never reads as invalid. Only a check that
    /// ran the CLI, to its exit or its timeout, counts towards `minInterval`, as does
    /// `lastAnswerAt`, as for `DatabricksChecker`.
    public func check(account: String, loginRunning: Bool, lastAnswerAt: Date? = nil) async -> DatabricksCheck {
        guard !loginRunning else { return .skipped }
        let now = clock()
        let storedAnswer = lastAnswerAt.flatMap { $0 <= now ? $0 : nil }
        if let last = [lastCheck[account], storedAnswer].compactMap({ $0 }).max(),
           now.timeIntervalSince(last) < minInterval
        {
            return .skipped
        }
        // Reserved before the first await, as DatabricksChecker does, since the actor is reentrant.
        let previousCheck = lastCheck[account]
        lastCheck[account] = now
        let path = await pathResolver.resolvePath()
        guard let executable = path.locate("gcloud") else {
            lastCheck[account] = previousCheck
            return .couldntCheck
        }
        let environment = path.childEnvironment(base: ProcessInfo.processInfo.environment)
        let outcome = await runner.runDiscardingStandardOutput(
            executable: executable,
            arguments: [
                "config", "config-helper", "--force-auth-refresh",
                "--account=\(gcloudAccountEmail(account))", "--format=none",
            ],
            environment: environment, timeout: .seconds(timeout))
        switch outcome {
        case .exited(0, _): return .valid
        case .exited(_, let errors):
            return Self.authFailures.contains(where: errors.contains) ? .invalid : .couldntCheck
        case .timedOut, .signalled: return .couldntCheck
        case .cancelled, .launchFailed:
            lastCheck[account] = previousCheck
            return .couldntCheck
        }
    }
}
