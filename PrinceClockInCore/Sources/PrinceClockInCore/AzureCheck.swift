import Foundation

/// Asks the Azure CLI whether a tenant still has a usable login. Runs
/// `az account get-access-token --tenant=<id> --output=none`: `--output=none` makes az print
/// nothing, and the run's stdout goes to `/dev/null` besides, so no token reaches the app. Its result
/// is a `DatabricksCheck`, which means the same for every CLI. az takes the credential of the
/// default subscription's user, not of the tenant's, so a check runs only while the tracked user is
/// that user.
public actor AzureChecker {
    /// What az writes to stderr when only a new `az login` helps: no account or token in the MSAL
    /// cache.
    private static let authFailures = [
        "Can't find token from MSAL cache",
        "does not exist in MSAL token cache",
    ]

    /// Entra error codes that mean the refresh token or session is gone and the user must sign in
    /// again: a revoked or expired grant, sign-in frequency, MFA required or expired, or a password
    /// change. az gives every Entra error the same advice to run `az login`, a server outage too, so
    /// that advice alone is no answer.
    private static let reauthCodes = [
        "AADSTS50173", "AADSTS70008", "AADSTS700082", "AADSTS70043", "AADSTS50078", "AADSTS50076",
        "AADSTS50079", "AADSTS50132", "AADSTS50133",
    ]

    private let runner: ProcessRunning
    private let pathResolver: any PathResolving
    private let profile: AzureProfileReading
    private let clock: @Sendable () -> Date
    private let minInterval: TimeInterval
    private let timeout: TimeInterval
    private var lastCheck: [AzureAccount: Date] = [:]

    public init(
        runner: ProcessRunning, pathResolver: any PathResolving, profile: AzureProfileReading,
        clock: @escaping @Sendable () -> Date = Date.init,
        minInterval: TimeInterval = 300, timeout: TimeInterval = 30
    ) {
        self.runner = runner
        self.pathResolver = pathResolver
        self.profile = profile
        self.clock = clock
        self.minInterval = minInterval
        self.timeout = timeout
    }

    /// `.valid` on exit 0 and `.invalid` on one of az's no-credentials or sign-in-again errors; any
    /// other failure is `.couldntCheck`, so an offline failure never reads as invalid. Only a check
    /// that ran the CLI, to its exit or its timeout, counts towards `minInterval`, as does
    /// `lastAnswerAt`, as for `DatabricksChecker`. `.skipped`, without
    /// running az, unless `azureProfile.json`'s default subscription is `account`'s user's, compared
    /// ignoring case, since az would answer for whichever user that is.
    public func check(account: AzureAccount, loginRunning: Bool, lastAnswerAt: Date? = nil) async -> DatabricksCheck {
        guard !loginRunning else { return .skipped }
        let now = clock()
        let storedAnswer = lastAnswerAt.flatMap { $0 <= now ? $0 : nil }
        if let last = [lastCheck[account], storedAnswer].compactMap({ $0 }).max(),
           now.timeIntervalSince(last) < minInterval
        {
            return .skipped
        }
        guard let activeUser = profile.read()?.defaultUser, isSameAzureUser(activeUser, account.user) else {
            return .skipped
        }
        // Reserved before the first await, as DatabricksChecker does, since the actor is reentrant.
        let previousCheck = lastCheck[account]
        lastCheck[account] = now
        let path = await pathResolver.resolvePath()
        guard let executable = path.locate("az") else {
            lastCheck[account] = previousCheck
            return .couldntCheck
        }
        let environment = path.childEnvironment(base: ProcessInfo.processInfo.environment)
        let outcome = await runner.runDiscardingStandardOutput(
            executable: executable,
            arguments: ["account", "get-access-token", "--tenant=\(account.tenant)", "--output=none"],
            environment: environment, timeout: .seconds(timeout))
        switch outcome {
        case .exited(0, _): return .valid
        case .exited(_, let errors): return Self.needsSignIn(errors) ? .invalid : .couldntCheck
        case .timedOut, .signalled: return .couldntCheck
        case .cancelled, .launchFailed:
            lastCheck[account] = previousCheck
            return .couldntCheck
        }
    }

    /// Whether `errors` holds a no-credentials message or a sign-in-again code. A code counts only
    /// when no digit follows it, so `AADSTS70008` doesn't match a longer code such as `AADSTS700084`.
    private static func needsSignIn(_ errors: String) -> Bool {
        if authFailures.contains(where: errors.contains) { return true }
        return reauthCodes.contains { code in
            var rest = errors[...]
            while let range = rest.range(of: code) {
                guard let next = rest[range.upperBound...].first, next.isASCII, next.isNumber else { return true }
                rest = rest[range.upperBound...]
            }
            return false
        }
    }
}
