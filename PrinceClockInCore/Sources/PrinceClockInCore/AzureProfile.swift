import Foundation

/// One user's sign-in to one tenant, as the Azure CLI's `azureProfile.json` lists it.
public struct AzureAccount: Hashable, Sendable {
    /// The subscription's `user.name`, the user's sign-in name.
    public let user: String
    /// The subscription's `tenantId`.
    public let tenant: String

    public init(user: String, tenant: String) {
        self.user = user
        self.tenant = tenant
    }

    /// Whether `other` is the same sign-in: the same tenant, and the same user ignoring case, as
    /// `az logout` matches users.
    public func isSameSignIn(as other: AzureAccount) -> Bool {
        tenant == other.tenant && isSameAzureUser(user, other.user)
    }
}

/// Whether two `user.name`s name one user: the Azure CLI compares them ignoring case.
func isSameAzureUser(_ first: String, _ second: String) -> Bool {
    first.lowercased() == second.lowercased()
}

/// An Azure CLI tenant that discovery offers: the account, and the name the + menu shows for it.
public struct AzureTenant: Equatable, Sendable {
    public let account: AzureAccount
    public let displayName: String

    public init(account: AzureAccount, displayName: String) {
        self.account = account
        self.displayName = displayName
    }
}

/// One user subscription of `azureProfile.json`, with the tenant names the CLI stored beside it.
public struct AzureSubscription: Equatable, Sendable {
    public let account: AzureAccount
    public let tenantDisplayName: String?
    public let tenantDefaultDomain: String?
    /// Whether it is the subscription az uses when a command names none (`az account set`).
    public let isDefault: Bool

    public init(
        account: AzureAccount, tenantDisplayName: String? = nil, tenantDefaultDomain: String? = nil,
        isDefault: Bool = false
    ) {
        self.account = account
        self.tenantDisplayName = tenantDisplayName
        self.tenantDefaultDomain = tenantDefaultDomain
        self.isDefault = isDefault
    }
}

/// What the app saw of the Azure CLI's `azureProfile.json`: its user subscriptions, in file order,
/// and when the file last changed. The file holds no credential.
public struct AzureProfile: Equatable, Sendable {
    /// Only subscriptions of `user.type` `user` outside Cloud Shell: service principals and managed
    /// identities are left out.
    public let subscriptions: [AzureSubscription]
    /// The file's modification date, whole seconds; `nil` when there is no file.
    public let modified: Date?

    /// No file, so no subscriptions.
    public static let none = AzureProfile(subscriptions: [], modified: nil)

    public init(subscriptions: [AzureSubscription], modified: Date?) {
        self.subscriptions = subscriptions
        self.modified = modified?.wholeSeconds
    }

    /// Whether any subscription of `account`'s user, ignoring case, and tenant is listed now.
    public func presence(of account: AzureAccount) -> AzurePresence {
        subscriptions.contains { $0.account.isSameSignIn(as: account) } ? .present : .missing
    }

    /// The user of the default subscription, the one az takes its credential from when a command
    /// names no subscription; `nil` when no user subscription is the default.
    public var defaultUser: String? {
        subscriptions.first(where: \.isDefault)?.account.user
    }
}

/// `azureProfile.json` in `configDirectory`.
public func azureProfileFile(configDirectory: URL) -> URL {
    configDirectory.appending(path: "azureProfile.json", directoryHint: .notDirectory)
}

/// The file a watch of the Azure config directory reacts to: every az command writes its logs and
/// telemetry there too, and `msal_token_cache.json` changes at each token refresh.
public let azureProfileFileNames: Set<String> = ["azureProfile.json"]

/// An `azureProfile.json` that exists but could not be read or parsed, as when the CLI is midway
/// through rewriting it. It names only the file.
public struct AzureProfileError: Error, Equatable, LocalizedError {
    public let fileName: String

    public init(fileName: String) {
        self.fileName = fileName
    }

    public var errorDescription: String? { "Could not read the Azure CLI's profile \(fileName)." }
}

/// Reads the user subscriptions of the `azureProfile.json` at `url`. The CLI writes it as UTF-8 with
/// a byte order mark, which is dropped before parsing. A missing file gives `.none`.
public func readAzureProfile(at url: URL) throws(AzureProfileError) -> AzureProfile {
    let failure = AzureProfileError(fileName: url.lastPathComponent)
    let manager = FileManager.default
    guard manager.fileExists(atPath: url.path) else { return .none }
    guard let modified = (try? manager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
          let data = try? Data(contentsOf: url)
    else { throw failure }
    return AzureProfile(subscriptions: try parseAzureProfile(data, failure: failure), modified: modified)
}

private func parseAzureProfile(_ data: Data, failure: AzureProfileError) throws(AzureProfileError) -> [AzureSubscription] {
    let byteOrderMark = Data([0xEF, 0xBB, 0xBF])
    let json = data.starts(with: byteOrderMark) ? data.dropFirst(byteOrderMark.count) : data
    guard let file = try? JSONDecoder().decode(ProfileFile.self, from: json) else { throw failure }
    return (file.subscriptions ?? []).compactMap { entry in
        guard let user = entry.user, user.type == "user", user.cloudShellID != true,
              let name = user.name, !name.isEmpty, let tenant = entry.tenantId, !tenant.isEmpty
        else { return nil }
        return AzureSubscription(
            account: AzureAccount(user: name, tenant: tenant), tenantDisplayName: entry.tenantDisplayName,
            tenantDefaultDomain: entry.tenantDefaultDomain, isDefault: entry.isDefault == true)
    }
}

private struct ProfileFile: Decodable {
    let subscriptions: [Entry]?

    struct Entry: Decodable {
        let tenantId: String?
        let tenantDisplayName: String?
        let tenantDefaultDomain: String?
        let isDefault: Bool?
        let user: User?
    }

    struct User: Decodable {
        let name: String?
        let type: String?
        let cloudShellID: Bool?
    }
}

/// Each user and tenant of `profile` once, in file order, named by the tenant's display name, else
/// its default domain, else its id. A tenant that more than one user signs in to gets the user in
/// parentheses after its name: "Contoso Dev (dev@example.com)".
public func discoverAzureTenants(_ profile: AzureProfile) -> [AzureTenant] {
    var accounts: [AzureAccount] = []
    var seen: Set<AzureAccount> = []
    var users: [String: Set<String>] = [:]
    var displayNames: [String: String] = [:]
    var domains: [String: String] = [:]
    for subscription in profile.subscriptions {
        let account = subscription.account
        if seen.insert(account).inserted { accounts.append(account) }
        users[account.tenant, default: []].insert(account.user)
        if displayNames[account.tenant] == nil, let name = nonEmpty(subscription.tenantDisplayName) {
            displayNames[account.tenant] = name
        }
        if domains[account.tenant] == nil, let domain = nonEmpty(subscription.tenantDefaultDomain) {
            domains[account.tenant] = domain
        }
    }
    return accounts.map { account in
        let tenantName = displayNames[account.tenant] ?? domains[account.tenant] ?? account.tenant
        let isShared = (users[account.tenant]?.count ?? 0) > 1
        return AzureTenant(account: account, displayName: isShared ? "\(tenantName) (\(account.user))" : tenantName)
    }
}

private func nonEmpty(_ text: String?) -> String? {
    text.flatMap { $0.isEmpty ? nil : $0 }
}

/// Whether `azureProfile.json` listed an Azure login's user and tenant, as read and as stored per
/// login.
public enum AzurePresence: String, Codable, Hashable, Sendable {
    case missing
    case present
}

/// What a change from `previous`, `nil` when never seen, to `current` means, for a profile last
/// modified at `modified`.
/// `az login` adds the tenant's subscriptions and `az logout` removes all of its user's, but the file
/// is also rewritten by `az account set` and `az account list --refresh`, never by a token refresh;
/// so only an appearance is a login, at `modified`, the best the app knows. Present before and now
/// is no change, even if the user logged in again; a first sight is a baseline.
public func observeAzurePresence(
    previous: AzurePresence?, current: AzurePresence, modified: Date
) -> GcloudObservation {
    switch (previous, current) {
    case (nil, _), (.missing, .missing), (.present, .present):
        .noChange
    case (.present, .missing):
        .loggedOut
    case (.missing, .present):
        .newLogin(at: modified)
    }
}
