import Foundation

/// What one check of a Databricks profile found.
public enum DatabricksCheck: Equatable, Sendable {
    /// The CLI answered with the profile's user.
    case valid
    /// The CLI's no-credentials error.
    case invalid
    /// The check failed for another reason: the CLI not found or not started, another error, or a
    /// timeout, such as when offline.
    case couldntCheck
    /// Not run: an account-level profile, a login running, or a check of this profile less than the
    /// minimum interval ago.
    case skipped

    /// The result to store; `nil` for a skipped check, which stores nothing.
    public var result: DatabricksCheckResult? {
        switch self {
        case .valid: .valid
        case .invalid: .invalid
        case .couldntCheck: .couldntCheck
        case .skipped: nil
        }
    }
}

/// Asks the Databricks CLI whether a profile still has a usable login. Runs
/// `databricks current-user me --profile <name>`, never `auth token`, which prints a token.
public actor DatabricksChecker {
    /// What the CLI prints when it holds no usable credentials for the profile.
    private static let authFailure = "error getting token: cache: no cached credentials"

    private let runner: ProcessRunning
    private let pathResolver: ShellPathResolver
    private let clock: @Sendable () -> Date
    private let minInterval: TimeInterval
    private let timeout: TimeInterval
    private var lastCheck: [String: Date] = [:]

    public init(
        runner: ProcessRunning, pathResolver: ShellPathResolver,
        clock: @escaping @Sendable () -> Date = Date.init,
        minInterval: TimeInterval = 300, timeout: TimeInterval = 30
    ) {
        self.runner = runner
        self.pathResolver = pathResolver
        self.clock = clock
        self.minInterval = minInterval
        self.timeout = timeout
    }

    /// `.valid` on exit 0 and `.invalid` on the CLI's no-credentials error; any other failure is
    /// `.couldntCheck`, so an offline or VPN-down failure never reads as invalid. Only a check that
    /// ran the CLI, to its exit or its timeout, counts towards `minInterval`.
    public func check(profile: String, accountLevel: Bool, loginRunning: Bool) async -> DatabricksCheck {
        guard !accountLevel, !loginRunning else { return .skipped }
        let now = clock()
        if let last = lastCheck[profile], now.timeIntervalSince(last) < minInterval { return .skipped }
        // Reserved before the first await: the actor is reentrant, so a second call arriving while
        // this one waits would otherwise pass the interval check too.
        let previousCheck = lastCheck[profile]
        lastCheck[profile] = now
        guard let executable = await pathResolver.locate("databricks") else {
            lastCheck[profile] = previousCheck
            return .couldntCheck
        }
        let environment = await pathResolver.childEnvironment(base: ProcessInfo.processInfo.environment)
        let outcome = await runner.run(
            executable: executable, arguments: ["current-user", "me", "--profile", profile],
            environment: environment, timeout: .seconds(timeout))
        switch outcome {
        case .exited(0, _): return .valid
        case .exited(_, let output): return output.contains(Self.authFailure) ? .invalid : .couldntCheck
        case .timedOut, .signalled: return .couldntCheck
        case .cancelled, .launchFailed:
            lastCheck[profile] = previousCheck
            return .couldntCheck
        }
    }
}
