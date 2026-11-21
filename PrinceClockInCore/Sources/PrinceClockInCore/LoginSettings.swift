import Foundation

/// The symbol shown, in `.secondary`, beside a login in Settings → Logins.
public func loginKindSymbolName(_ kind: LoginKind) -> String {
    switch kind {
    case .awsSSOSession: "cloud"
    case .databricksProfile: "square.stack.3d.up"
    case .gcloudAccount: "person.badge.key"
    case .azureTenant: "building.2"
    case .custom: "terminal"
    }
}

/// A login's row subtitle in Settings → Logins: its kind, its session length ("No timer" when
/// unknown) and, for Databricks, gcloud and Azure, its last check ("Databricks profile · 3-day
/// session · Checked 14:02 · valid"). An account profile ends with "Not checked"; a login never
/// checked has no check in it.
public func loginRowSubtitle(for login: Login, now: Date, locale: Locale, calendar: Calendar) -> String {
    let session = login.sessionLength.map { "\(sessionLengthAdjective($0)) session" } ?? "No timer"
    var parts = [loginKindName(login.kind), session]
    switch login.kind {
    case .databricksProfile(_, accountLevel: true):
        parts.append("Not checked")
    case .databricksProfile, .gcloudAccount, .azureTenant:
        if let check = login.lastDatabricksCheck {
            parts.append(checkText(check, now: now, locale: locale, calendar: calendar))
        }
    case .awsSSOSession, .custom:
        break
    }
    return parts.joined(separator: " · ")
}

/// Where an AWS SSO session, Databricks profile, gcloud account or Azure tenant comes from, as the
/// form shows it.
public struct LoginSource: Equatable, Sendable {
    /// "SSO session", "Profile", "Account" or "Tenant".
    public let label: String
    /// The CLI's name in the config file, "qa in ~/.aws/config".
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// A Databricks profile's, gcloud account's or Azure tenant's last check, as the form shows it.
public struct LastCheck: Equatable, Sendable {
    /// "Checked 14:02 · valid", "Not checked yet", or "Not checked" for an account profile.
    public let text: String
    /// Why an account profile is never checked.
    public let note: String?

    public init(text: String, note: String?) {
        self.text = text
        self.note = note
    }
}

/// What the selected login's form in Settings → Logins shows beside its Name and Session length.
public struct LoginSettingsForm: Equatable, Sendable {
    /// Under Name: the name is only what PrinceClockIn shows.
    public let nameNote: String
    /// `nil` for a custom login.
    public let source: LoginSource?
    /// `nil` for anything but a Databricks profile, gcloud account or Azure tenant.
    public let lastCheck: LastCheck?
    /// Under a custom login's Command; `nil` for the other kinds.
    public let commandNote: String?
}

/// The note under a custom login's Command, in its form and in New custom login.
public let customCommandNote = "The command runs in Terminal and is saved as plain text, so don't put a secret in it."

/// The form for `login`. A config file under `home` is shown with `~` in its place.
public func loginSettingsForm(
    for login: Login, paths: ConfigPaths, home: URL, now: Date, locale: Locale, calendar: Calendar
) -> LoginSettingsForm {
    let shown = "The name is only what PrinceClockIn shows"
    switch login.kind {
    case .awsSSOSession(let name):
        return LoginSettingsForm(
            nameNote: "\(shown); the SSO session's name in your config stays as it is.",
            source: LoginSource(label: "SSO session", value: "\(name) in \(displayPath(paths.awsConfig, home: home))"),
            lastCheck: nil, commandNote: nil)
    case .databricksProfile(let name, let accountLevel):
        let lastCheck = if accountLevel {
            LastCheck(
                text: "Not checked",
                note: "The Databricks CLI can't check an account profile, so this login runs on its timer alone.")
        } else {
            LastCheck(
                text: login.lastDatabricksCheck.map { checkText($0, now: now, locale: locale, calendar: calendar) }
                    ?? "Not checked yet",
                note: nil)
        }
        return LoginSettingsForm(
            nameNote: "\(shown); the profile's name in your config stays as it is.",
            source: LoginSource(
                label: "Profile", value: "\(name) in \(displayPath(paths.databricksConfig, home: home))"),
            lastCheck: lastCheck, commandNote: nil)
    case .gcloudAccount(let account):
        return LoginSettingsForm(
            nameNote: "\(shown); the account in gcloud stays as it is.",
            source: LoginSource(
                label: "Account",
                value: "\(account) in \(displayPath(paths.gcloudConfig, home: home))"),
            lastCheck: LastCheck(
                text: login.lastDatabricksCheck.map { checkText($0, now: now, locale: locale, calendar: calendar) }
                    ?? "Not checked yet",
                note: nil),
            commandNote: nil)
    case .azureTenant(let user, let tenant):
        return LoginSettingsForm(
            nameNote: "\(shown); the tenant in the Azure CLI stays as it is.",
            source: LoginSource(
                label: "Tenant",
                value: "\(tenant) for \(user) in \(displayPath(paths.azureConfig, home: home))"),
            lastCheck: LastCheck(
                text: login.lastDatabricksCheck.map { checkText($0, now: now, locale: locale, calendar: calendar) }
                    ?? "Not checked yet",
                note: nil),
            commandNote: nil)
    case .custom:
        return LoginSettingsForm(nameNote: "\(shown).", source: nil, lastCheck: nil, commandNote: customCommandNote)
    }
}

/// "Checked 14:02 · valid", with the day as well when the check wasn't today.
private func checkText(_ check: DatabricksCheckRecord, now: Date, locale: Locale, calendar: Calendar) -> String {
    let when = calendar.isDate(check.at, inSameDayAs: now)
        ? clockTimeText(check.at, locale: locale, calendar: calendar)
        : dayAndTimeText(check.at, locale: locale, calendar: calendar)
    let result = switch check.result {
    case .valid: "valid"
    case .invalid: "invalid"
    case .couldntCheck: "couldn't check"
    }
    return "Checked \(when) · \(result)"
}

/// `url`'s path, with `~` for `home` when the file is under it.
private func displayPath(_ url: URL, home: URL) -> String {
    let path = url.path(percentEncoded: false)
    let homePath = home.path(percentEncoded: false).trimmingSuffix("/")
    if path == homePath { return "~" }
    guard path.hasPrefix(homePath + "/") else { return path }
    return "~" + path.dropFirst(homePath.count)
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
