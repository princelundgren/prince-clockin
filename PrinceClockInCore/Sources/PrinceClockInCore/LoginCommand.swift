/// An executable name and its argument list, run without a shell.
public struct LoginCommand: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

/// The CLI command that signs in to `kind`, or `nil` for a custom login, which the app doesn't run.
/// The name is joined to its flag in one argument, so a name that starts with `-` can't be read as
/// a flag of its own; for gcloud that is the account's email. gcloud also gets `--force`, without
/// which it only makes an account with stored credentials active and doesn't sign in.
public func loginCommand(for kind: LoginKind) -> LoginCommand? {
    switch kind {
    case .awsSSOSession(let name):
        LoginCommand(executable: "aws", arguments: ["sso", "login", "--sso-session=\(name)"])
    case .databricksProfile(let name, _):
        LoginCommand(executable: "databricks", arguments: ["auth", "login", "--profile=\(name)"])
    case .gcloudAccount(let account):
        LoginCommand(executable: "gcloud", arguments: ["auth", "login", "--force", "--account=\(gcloudAccountEmail(account))"])
    case .custom:
        nil
    }
}
