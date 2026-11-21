/// An executable name and its argument list, run without a shell.
public struct LoginCommand: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

/// The CLI command that signs in to `kind`, or `nil` for a custom login, which the app doesn't run,
/// and for an OCI session profile, whose command depends on its config: `ociLoginCommand`.
/// The name is joined to its flag in one argument, so a name that starts with `-` can't be read as
/// a flag of its own; for gcloud that is the account's email. gcloud also gets `--force`, without
/// which it doesn't sign in an account with valid stored credentials, and `--no-activate`, so the
/// login leaves gcloud's active account and project as they were. The Azure CLI
/// signs in to the tenant; the browser chooses the user. With stdin and stdout not a terminal, as
/// the app runs it, `az login` shows no subscription picker; `--allow-no-subscriptions` lets a
/// tenant with no subscription sign in, which az otherwise refuses.
public func loginCommand(for kind: LoginKind) -> LoginCommand? {
    switch kind {
    case .awsSSOSession(let name):
        LoginCommand(executable: "aws", arguments: ["sso", "login", "--sso-session=\(name)"])
    case .databricksProfile(let name, _):
        LoginCommand(executable: "databricks", arguments: ["auth", "login", "--profile=\(name)"])
    case .gcloudAccount(let account):
        LoginCommand(executable: "gcloud", arguments: ["auth", "login", "--force", "--no-activate", "--account=\(gcloudAccountEmail(account))"])
    case .azureTenant(_, let tenant):
        LoginCommand(executable: "az", arguments: ["login", "--tenant=\(tenant)", "--allow-no-subscriptions"])
    case .ociSessionProfile, .custom:
        nil
    }
}
