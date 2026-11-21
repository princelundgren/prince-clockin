import Foundation
import Testing
import PrinceClockInCore

private let seen = at("2026-11-17T09:00:00Z")
private let contoso = "00000000-0000-0000-0000-000000000001"
private let fabrikam = "00000000-0000-0000-0000-000000000002"
private let northwind = "00000000-0000-0000-0000-000000000003"

/// A subscription in the shape azure-cli 2.93.0 stores it; `userExtra` and `extra` add keys to its
/// user and to it.
private func subscription(
    user: String = "dev@example.com", type: String = "user", userExtra: String = "", tenant: String = contoso,
    name: String = "Contoso Dev Subscription", extra: String = ""
) -> String {
    #"{"id": "11111111-1111-1111-1111-111111111111", "name": "\#(name)", "state": "Enabled", "#
        + #""user": {"name": "\#(user)", "type": "\#(type)"\#(userExtra)}, "isDefault": false, "tenantId": "\#(tenant)", "#
        + #""homeTenantId": "\#(tenant)", "environmentName": "AzureCloud", "managedByTenants": []\#(extra)}"#
}

/// `azureProfile.json` as the CLI writes it: `json.dump` with `utf-8-sig`, so a byte order mark first.
private func profileData(_ subscriptions: [String], byteOrderMark: Bool = true) -> Data {
    let json = #"{"installationId": "22222222-2222-2222-2222-222222222222", "subscriptions": ["#
        + subscriptions.joined(separator: ", ") + "]}"
    return (byteOrderMark ? Data([0xEF, 0xBB, 0xBF]) : Data()) + Data(json.utf8)
}

private func writeProfile(_ data: Data) throws -> URL {
    let file = try makeTemporaryDirectory().appending(path: "azureProfile.json")
    try data.write(to: file)
    return file
}

private func account(_ user: String = "dev@example.com", _ tenant: String = contoso) -> AzureAccount {
    AzureAccount(user: user, tenant: tenant)
}

@Suite struct AzureProfileTests {
    // MARK: Reading the file

    @Test func aFileWithAByteOrderMarkIsRead() throws {
        let file = try writeProfile(profileData([subscription()]))
        try FileManager.default.setAttributes([.modificationDate: seen], ofItemAtPath: file.path)

        let profile = try readAzureProfile(at: file)

        #expect(profile.subscriptions == [AzureSubscription(account: account())])
        #expect(profile.modified == seen)
        #expect(profile.presence(of: account()) == .present)
        #expect(profile.presence(of: account("ops@example.com")) == .missing)
    }

    @Test func theDefaultSubscriptionNamesTheActiveUser() throws {
        let file = try writeProfile(profileData([
            subscription(),
            subscription(user: "ops@example.com").replacingOccurrences(of: #""isDefault": false"#, with: #""isDefault": true"#),
        ]))

        #expect(try readAzureProfile(at: file).defaultUser == "ops@example.com")
        #expect(try readAzureProfile(at: writeProfile(profileData([subscription()]))).defaultUser == nil)
    }

    @Test func presenceMatchesTheUserIgnoringCase() {
        let profile = AzureProfile(subscriptions: [AzureSubscription(account: account("Dev@Example.COM"))], modified: nil)

        #expect(profile.presence(of: account("dev@example.com")) == .present)
        #expect(profile.presence(of: account("dev@example.com", fabrikam)) == .missing)
    }

    @Test func aFileWithoutAByteOrderMarkIsReadToo() throws {
        let file = try writeProfile(profileData([subscription()], byteOrderMark: false))

        #expect(try readAzureProfile(at: file).subscriptions.map(\.account) == [account()])
    }

    @Test func aMissingFileHasNoSubscriptions() throws {
        let missing = try makeTemporaryDirectory().appending(path: "azureProfile.json")

        #expect(try readAzureProfile(at: missing) == .none)
    }

    @Test func aFileWithOnlyAnInstallationIDHasNoSubscriptions() throws {
        let file = try writeProfile(Data([0xEF, 0xBB, 0xBF]) + Data(#"{"installationId": "x"}"#.utf8))

        #expect(try readAzureProfile(at: file).subscriptions.isEmpty)
    }

    @Test func aHalfWrittenFileCantBeRead() throws {
        let whole = profileData([subscription(), subscription(user: "ops@example.com")])
        for length in [0, 3, whole.count / 2, whole.count - 1] {
            let file = try writeProfile(whole.prefix(length))

            #expect(throws: AzureProfileError(fileName: "azureProfile.json"), "\(length) bytes") {
                try readAzureProfile(at: file)
            }
        }
    }

    @Test func serviceTenantsManagedIdentitiesAndCloudShellAreLeftOut() throws {
        let file = try writeProfile(profileData([
            subscription(user: "33333333-3333-3333-3333-333333333333", type: "servicePrincipal"),
            subscription(
                user: "systemAssignedIdentity", type: "servicePrincipal", userExtra: #", "assignedIdentityInfo": "MSI""#),
            subscription(user: "userAssignedIdentity", type: "servicePrincipal", userExtra: #", "assignedIdentityInfo": "MSIClient-x""#),
            subscription(user: "ops@example.com", userExtra: #", "cloudShellID": true"#),
            subscription(),
        ]))

        #expect(try readAzureProfile(at: file).subscriptions.map(\.account) == [account()])
    }

    @Test func theConfigDirectoryHoldsTheProfile() {
        #expect(azureProfileFile(configDirectory: URL(filePath: "/Users/someone/.azure")).path
            == "/Users/someone/.azure/azureProfile.json")
        #expect(azureProfileFileNames == ["azureProfile.json"])
    }

    @Test func theConfigDirectoryFollowsAzureConfigDir() {
        let home = ["HOME": "/Users/someone"]
        #expect(ConfigPaths.standard(environment: home).azureConfig.path == "/Users/someone/.azure")
        #expect(ConfigPaths.standard(environment: home.merging(["AZURE_CONFIG_DIR": "~/azure-dev"]) { $1 })
            .azureConfig.path == "/Users/someone/azure-dev")
        #expect(ConfigPaths.standard(environment: home.merging(["AZURE_CONFIG_DIR": "/opt/azure"]) { $1 })
            .azureConfig.path == "/opt/azure")
        #expect(ConfigPaths.standard(environment: home.merging(["AZURE_CONFIG_DIR": ""]) { $1 })
            .azureConfig.path == "/Users/someone/.azure")
    }

    // MARK: Discovery

    @Test func discoveryOffersEachUserAndTenantOnceInFileOrder() throws {
        let file = try writeProfile(profileData([
            subscription(tenant: fabrikam, extra: #", "tenantDisplayName": "Fabrikam""#),
            subscription(tenant: contoso, extra: #", "tenantDisplayName": "Contoso Dev""#),
            subscription(tenant: fabrikam, name: "Fabrikam Other", extra: #", "tenantDisplayName": "Fabrikam""#),
        ]))

        let tenants = discoverAzureTenants(try readAzureProfile(at: file))

        #expect(tenants == [
            AzureTenant(account: account("dev@example.com", fabrikam), displayName: "Fabrikam"),
            AzureTenant(account: account("dev@example.com", contoso), displayName: "Contoso Dev"),
        ])
    }

    @Test func aTenantIsNamedByItsDisplayNameElseItsDomainElseItsID() throws {
        let file = try writeProfile(profileData([
            subscription(tenant: contoso, name: "N/A(tenant level account)"),
            subscription(tenant: contoso, extra: #", "tenantDisplayName": "", "tenantDefaultDomain": "contoso.example.com""#),
            subscription(tenant: contoso, extra: #", "tenantDisplayName": "Contoso Dev""#),
            subscription(tenant: fabrikam, extra: #", "tenantDefaultDomain": "fabrikam.example.com""#),
            subscription(tenant: northwind, name: "N/A(tenant level account)"),
        ]))

        let names = discoverAzureTenants(try readAzureProfile(at: file)).map(\.displayName)

        #expect(names == ["Contoso Dev", "fabrikam.example.com", northwind])
    }

    @Test func aTenantWithSeveralUsersNamesTheUser() throws {
        let file = try writeProfile(profileData([
            subscription(user: "dev@example.com", extra: #", "tenantDisplayName": "Contoso Dev""#),
            subscription(user: "ops@example.com", extra: #", "tenantDisplayName": "Contoso Dev""#),
            subscription(user: "dev@example.com", tenant: fabrikam, extra: #", "tenantDisplayName": "Fabrikam""#),
        ]))

        let names = discoverAzureTenants(try readAzureProfile(at: file)).map(\.displayName)

        #expect(names == ["Contoso Dev (dev@example.com)", "Contoso Dev (ops@example.com)", "Fabrikam"])
    }

    // MARK: What a change means

    @Test func appearingAfterMissingIsALoginAtTheFilesTime() {
        #expect(observeAzurePresence(previous: .missing, current: .present, modified: seen) == .newLogin(at: seen))
    }

    @Test func goingAfterPresentIsALogout() {
        #expect(observeAzurePresence(previous: .present, current: .missing, modified: seen) == .loggedOut)
    }

    @Test func presentAfterPresentIsNothing() {
        #expect(observeAzurePresence(previous: .present, current: .present, modified: seen) == .noChange)
        #expect(observeAzurePresence(previous: .missing, current: .missing, modified: seen) == .noChange)
    }

    @Test func aFirstSightIsOnlyABaseline() {
        #expect(observeAzurePresence(previous: nil, current: .present, modified: seen) == .noChange)
        #expect(observeAzurePresence(previous: nil, current: .missing, modified: seen) == .noChange)
    }
}
