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
            parts.append(databricksCheckText(check, now: now, locale: locale, calendar: calendar))
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
    /// The CLI's name for it, "qa".
    public let value: String
    /// Under the row: the config file it is in, "In ~/.aws/config.".
    public let note: String
    /// That config file, or for gcloud and Azure their config folder, for Show in Finder.
    public let file: URL

    public init(label: String, value: String, note: String, file: URL) {
        self.label = label
        self.value = value
        self.note = note
        self.file = file
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
    /// Under Name: renaming leaves the CLI's own name as it is; `nil` for a custom login, which
    /// has no other name.
    public let nameNote: String?
    /// `nil` for a custom login.
    public let source: LoginSource?
    /// `nil` for anything but a Databricks profile, gcloud account or Azure tenant.
    public let lastCheck: LastCheck?
    /// Under a custom login's Command; `nil` for the other kinds.
    public let commandNote: String?
}

/// The note under Session length for a login of `kind` while its pop-up shows `choice`: what the
/// length is for, who sets it for that kind, and, with No timer, what the login goes without.
public func sessionLengthNote(for kind: LoginKind, choice: SessionLengthChoice) -> String {
    let purpose = if case .custom = kind {
        "How long a sign-in lasts before you must log in again. PrinceClockIn counts down from it and notifies"
            + " you before it ends."
    } else {
        "How long a sign-in lasts before you must log in again. The CLI doesn't report it, so PrinceClockIn"
            + " counts down from it and notifies you before it ends."
    }
    let noTimer = choice == .noTimer ? "With No timer, this login has no countdown and no notification." : nil
    return [purpose, sessionLengthSetBy(kind), noTimer].compactMap(\.self).joined(separator: " ")
}

/// Where the real session length for `kind` comes from, so the user knows what to copy into
/// Session length; `nil` for a custom login.
private func sessionLengthSetBy(_ kind: LoginKind) -> String? {
    switch kind {
    case .awsSSOSession:
        "Your admin sets it in IAM Identity Center; its default is 8 hours."
    case .databricksProfile:
        "Your account admin sets it in the account's OAuth token policy."
    case .gcloudAccount:
        "Your Google Workspace admin sets it in Google Cloud session control."
    case .azureTenant:
        "Your admin sets it as the sign-in frequency in Entra Conditional Access."
    case .custom:
        nil
    }
}

/// The note under a custom login's Command, in its form and in New custom login.
public let customCommandNote = "The command runs in Terminal and is saved as plain text, so don't put a secret in it."

/// The form for `login`. A config file under `home` is shown with `~` in its place.
public func loginSettingsForm(
    for login: Login, paths: ConfigPaths, home: URL, now: Date, locale: Locale, calendar: Calendar
) -> LoginSettingsForm {
    let renamingOnlyHere = "Only changes the name in PrinceClockIn, not in"
    func source(_ label: String, _ value: String, in file: URL) -> LoginSource {
        LoginSource(label: label, value: value, note: "In \(displayPath(file, home: home)).", file: file)
    }
    switch login.kind {
    case .awsSSOSession(let name):
        return LoginSettingsForm(
            nameNote: "\(renamingOnlyHere) your config.",
            source: source("SSO session", name, in: paths.awsConfig),
            lastCheck: nil, commandNote: nil)
    case .databricksProfile(let name, let accountLevel):
        let lastCheck = if accountLevel {
            LastCheck(
                text: "Not checked",
                note: "The Databricks CLI can't check an account profile, so this login runs on its timer alone.")
        } else {
            LastCheck(
                text: login.lastDatabricksCheck.map { databricksCheckText($0, now: now, locale: locale, calendar: calendar) }
                    ?? "Not checked yet",
                note: nil)
        }
        return LoginSettingsForm(
            nameNote: "\(renamingOnlyHere) your config.",
            source: source("Profile", name, in: paths.databricksConfig),
            lastCheck: lastCheck, commandNote: nil)
    case .gcloudAccount(let account):
        return LoginSettingsForm(
            nameNote: "\(renamingOnlyHere) gcloud.",
            source: source("Account", account, in: paths.gcloudConfig),
            lastCheck: LastCheck(
                text: login.lastDatabricksCheck.map { databricksCheckText($0, now: now, locale: locale, calendar: calendar) }
                    ?? "Not checked yet",
                note: nil),
            commandNote: nil)
    case .azureTenant(let user, let tenant):
        return LoginSettingsForm(
            nameNote: "\(renamingOnlyHere) the Azure CLI.",
            source: source("Tenant", "\(tenant) for \(user)", in: paths.azureConfig),
            lastCheck: LastCheck(
                text: login.lastDatabricksCheck.map { databricksCheckText($0, now: now, locale: locale, calendar: calendar) }
                    ?? "Not checked yet",
                note: nil),
            commandNote: nil)
    case .custom:
        return LoginSettingsForm(
            nameNote: nil, source: nil, lastCheck: nil, commandNote: customCommandNote)
    }
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
