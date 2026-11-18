import Foundation

public enum DatabricksValidity: Equatable, Sendable {
    case valid
    case invalid
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

    /// `.valid` on exit 0 and `.invalid` on the CLI's no-credentials error. `nil` when skipped (an
    /// account-level profile, a login running, a check for this profile less than `minInterval` ago)
    /// and for any other outcome, so an offline or VPN-down failure changes nothing.
    public func check(profile: String, accountLevel: Bool, loginRunning: Bool) async -> DatabricksValidity? {
        guard !accountLevel, !loginRunning else { return nil }
        let now = clock()
        if let last = lastCheck[profile], now.timeIntervalSince(last) < minInterval { return nil }
        // Reserved before the first await: the actor is reentrant, so a second call arriving while
        // this one waits would otherwise pass the interval check too.
        let previousCheck = lastCheck[profile]
        lastCheck[profile] = now
        guard let executable = await pathResolver.locate("databricks") else {
            lastCheck[profile] = previousCheck
            return nil
        }
        let environment = await pathResolver.childEnvironment(base: ProcessInfo.processInfo.environment)
        let outcome = await runner.run(
            executable: executable, arguments: ["current-user", "me", "--profile", profile],
            environment: environment, timeout: .seconds(timeout))
        guard case .exited(let code, let output) = outcome else { return nil }
        if code == 0 { return .valid }
        return output.contains(Self.authFailure) ? .invalid : nil
    }
}
