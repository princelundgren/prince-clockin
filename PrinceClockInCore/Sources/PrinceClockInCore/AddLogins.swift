import Foundation

/// An AWS SSO session, Databricks profile, gcloud account, Azure CLI tenant or OCI session profile
/// found in the config files and not yet tracked.
public enum AddLoginCandidate: Equatable, Sendable {
    case awsSSOSession(name: String)
    case databricksProfile(DatabricksProfile)
    /// A store `account_id`; see `LoginKind.gcloudAccount`.
    case gcloudAccount(account: String)
    case azureTenant(AzureTenant)
    case ociSessionProfile(name: String)

    /// The login that tracks it: named as in the config file, a gcloud account by its email and an
    /// Azure tenant by its discovered name, with its kind's default length.
    public func login() -> Login {
        Login(displayName: name, kind: loginKind, sessionLength: Login.defaultSessionLength(for: loginKind))
    }

    var loginKind: LoginKind {
        switch self {
        case .awsSSOSession(let name): .awsSSOSession(name: name)
        case .databricksProfile(let profile): .databricksProfile(name: profile.name, accountLevel: profile.accountLevel)
        case .gcloudAccount(let account): .gcloudAccount(account: account)
        case .azureTenant(let tenant): .azureTenant(user: tenant.account.user, tenant: tenant.account.tenant)
        case .ociSessionProfile(let name): .ociSessionProfile(name: name)
        }
    }

    var name: String {
        switch self {
        case .awsSSOSession(let name): name
        case .databricksProfile(let profile): profile.name
        case .gcloudAccount(let account): gcloudAccountEmail(account)
        case .azureTenant(let tenant): tenant.displayName
        case .ociSessionProfile(let name): name
        }
    }
}

/// The AWS SSO session, Databricks profile, gcloud account, Azure tenant and OCI profile names that
/// tracked logins use: what discovery leaves out of the + menu, so its read of the config files
/// need only be redone when these change.
public struct TrackedConfigNames: Hashable, Sendable {
    public let aws: Set<String>
    public let databricks: Set<String>
    /// Store `account_id`s.
    public let gcloud: Set<String>
    public let azure: Set<AzureAccount>
    public let oci: Set<String>

    public init(logins: [Login]) {
        var aws: Set<String> = []
        var databricks: Set<String> = []
        var gcloud: Set<String> = []
        var azure: Set<AzureAccount> = []
        var oci: Set<String> = []
        for login in logins {
            switch login.kind {
            case .awsSSOSession(let name): aws.insert(name)
            case .databricksProfile(let name, _): databricks.insert(name)
            case .gcloudAccount(let account): gcloud.insert(account)
            case .azureTenant(let user, let tenant): azure.insert(AzureAccount(user: user, tenant: tenant))
            case .ociSessionProfile(let name): oci.insert(name)
            case .custom: break
            }
        }
        self.aws = aws
        self.databricks = databricks
        self.gcloud = gcloud
        self.azure = azure
        self.oci = oci
    }
}

/// One item of Settings → Logins' + menu.
public enum AddMenuItem: Equatable, Sendable {
    /// A section header.
    case header(String)
    /// A login found in the config files; choosing it tracks it.
    case found(AddLoginCandidate)
    /// A line that can't be chosen.
    case note(String)
    /// Opens New custom login.
    case customLogin

    public var title: String {
        switch self {
        case .header(let title), .note(let title): title
        case .found(let candidate): candidate.name
        case .customLogin: "Custom Login…"
        }
    }

    /// The kind shown beside a found login; `nil` for the other items.
    public var kind: String? {
        if case .found(let candidate) = self { loginKindName(candidate.loginKind) } else { nil }
    }
}

/// The + menu for what discovery found that isn't tracked: under "Found in your config files", the
/// AWS SSO sessions, then the Databricks profiles, then the account profiles, each in file order,
/// then the gcloud accounts, the Azure CLI tenants and the OCI session profiles, each in
/// discovery's order; then Custom Login…. With nothing found it says so; while the files are still
/// being read (`found` is `nil`) it offers Custom Login… alone.
public func addMenu(found: DiscoveredLogins?) -> [AddMenuItem] {
    guard let found else { return [.customLogin] }
    let workspaces = found.databricks.filter { !$0.accountLevel }
    let accounts = found.databricks.filter(\.accountLevel)
    let candidates = found.aws.map(AddLoginCandidate.awsSSOSession)
        + (workspaces + accounts).map(AddLoginCandidate.databricksProfile)
        + found.gcloud.map(AddLoginCandidate.gcloudAccount)
        + found.azure.map(AddLoginCandidate.azureTenant)
        + found.oci.map(AddLoginCandidate.ociSessionProfile)
    guard !candidates.isEmpty else {
        return [
            .note("No new AWS SSO sessions, Databricks profiles, gcloud accounts, Azure CLI tenants or OCI session "
                + "profiles"),
            .customLogin,
        ]
    }
    return [.header("Found in your config files")] + candidates.map(AddMenuItem.found) + [.customLogin]
}

/// −'s help tag: the login it removes.
public func removeLoginHelp(for login: Login?) -> String {
    guard let login else { return "Remove the selected login." }
    return "Remove \(login.displayName)."
}

/// What − asks before removing a login that is in a preset.
public struct RemoveLoginConfirmation: Equatable, Sendable {
    /// The login Remove removes.
    public let loginID: UUID
    /// "Remove vpn?"
    public let title: String
    /// "It also leaves the presets Morning and Night shift."
    public let message: String

    public init(loginID: UUID, title: String, message: String) {
        self.loginID = loginID
        self.title = title
        self.message = message
    }
}

/// What − asks before removing `login`, naming the presets it leaves, joined as `locale` joins a
/// list; `nil` for a login in no preset, which − removes at once.
public func removeLoginConfirmation(for login: Login, presets: [Preset], locale: Locale) -> RemoveLoginConfirmation? {
    let names = presets.filter { $0.loginIDs.contains(login.id) }.map(\.name)
    guard !names.isEmpty else { return nil }
    let presetWord = names.count == 1 ? "preset" : "presets"
    let list = names.formatted(.list(type: .and).locale(locale))
    return RemoveLoginConfirmation(
        loginID: login.id, title: "Remove \(login.displayName)?", message: "It also leaves the \(presetWord) \(list).")
}

/// What New custom login's fields hold, as typed.
public struct NewCustomLoginDraft: Equatable, Sendable {
    public var name = ""
    public var command = ""
    /// The Session Length pop-up's choice, from `sessionLengthOptions()`.
    public var sessionLength: SessionLengthChoice = .noTimer
    /// Custom…'s number of hours, as the session length field reads it.
    public var customHours = ""

    public init() {}

    /// Whether Add can add the login, and which: the name and command trimmed, an empty command
    /// none, and Custom…'s hours read as `sessionLength(fieldText:locale:)` reads them, except that
    /// Custom… with no hours is refused rather than read as no timer.
    public func check(locale: Locale) -> NewCustomLoginCheck {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .needsName }
        let length: TimeInterval?
        switch sessionLength {
        case .length(let listed):
            length = listed
        case .noTimer:
            length = nil
        case .custom:
            do throws(SessionLengthRefusal) {
                guard let typed = try PrinceClockInCore.sessionLength(fieldText: customHours, locale: locale) else {
                    return .refused(.notANumberOfHours)
                }
                length = typed
            } catch {
                return .refused(error)
            }
        }
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return .ready(Login(
            displayName: name, kind: .custom(command: command.isEmpty ? nil : command), sessionLength: length))
    }

    /// While there is no command: Log In waits for the user to click Done.
    public var noCommandNote: String? {
        guard command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return "Without a command, Log In waits for you to log in your own way and click Done."
    }
}

/// Whether New custom login's Add can add the login.
public enum NewCustomLoginCheck: Equatable, Sendable {
    case needsName
    /// The session length's refusal, shown under its field.
    case refused(SessionLengthRefusal)
    case ready(Login)
}

/// The prompt shown right after a login found in the config files is added.
public func addedLoginPrompt(name: String) -> String {
    "Already logged in to \(name)? Set its timer now so it can notify you before it expires, or skip and log in "
        + "from the panel later."
}
