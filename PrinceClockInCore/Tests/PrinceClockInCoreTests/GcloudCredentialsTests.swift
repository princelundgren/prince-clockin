import Foundation
import Testing
import PrinceClockInCore

private let seen = at("2026-11-17T09:00:00Z")

@Suite struct GcloudCredentialsTests {
    // MARK: Reading the store

    @Test func eachRowLoggedInGetsALargerRowID() throws {
        let store = try GcloudStoreFixture(at: try makeTemporaryDirectory().appending(path: "credentials.db"))
        try store.replace("a@example.com")
        try store.replace("b@example.com")
        #expect(try store.rowID(of: "a@example.com") == 1)
        #expect(try store.rowID(of: "b@example.com") == 2)

        try store.replace("b@example.com")
        try store.replace("a@example.com")

        #expect(try store.rowID(of: "b@example.com") == 3)
        #expect(try store.rowID(of: "a@example.com") == 4)
    }

    @Test func aMissingStoreHasNoAccounts() throws {
        let missing = try makeTemporaryDirectory().appending(path: "credentials.db")

        #expect(try readGcloudCredentials(at: missing) == .none)
    }

    @Test func aFileThatIsNoStoreCantBeRead() throws {
        let file = try makeTemporaryDirectory().appending(path: "credentials.db")
        try "not a database".write(to: file, atomically: true, encoding: .utf8)

        #expect(throws: GcloudCredentialsError(fileName: "credentials.db")) { try readGcloudCredentials(at: file) }
    }

    @Test func readingCarriesTheFilesModificationDate() throws {
        let file = try makeTemporaryDirectory().appending(path: "credentials.db")
        let store = try GcloudStoreFixture(at: file)
        try store.replace("dev@example.com")
        try FileManager.default.setAttributes([.modificationDate: seen], ofItemAtPath: file.path)

        let credentials = try readGcloudCredentials(at: file)

        #expect(credentials.modified == seen)
        #expect(credentials.state(account: "dev@example.com") == .present(rowID: 1))
        #expect(credentials.state(account: "ops@example.com") == .missing)
    }

    @Test func theConfigDirectoryHoldsTheStore() {
        let directory = URL(filePath: "/Users/someone/.config/gcloud")

        #expect(gcloudCredentialsFile(configDirectory: directory).path == "/Users/someone/.config/gcloud/credentials.db")
    }

    // MARK: Discovery

    @Test func discoveryOffersUserAccountsInLoginOrderAndNoServiceAccounts() throws {
        let file = try makeTemporaryDirectory().appending(path: "credentials.db")
        let store = try GcloudStoreFixture(at: file)
        try store.replace("ops@example.com")
        try store.replace("deploy@analytics-dev.iam.gserviceaccount.com")
        try store.replace("dev@example.com#example.goog")
        try store.replace("ci@analytics-dev.iam.gserviceaccount.com#example.goog")

        let accounts = discoverGcloudAccounts(try readGcloudCredentials(at: file))

        #expect(accounts == ["ops@example.com", "dev@example.com#example.goog"])
    }

    @Test func anAccountsEmailDropsItsUniverseDomain() {
        #expect(gcloudAccountEmail("dev@example.com#example.goog") == "dev@example.com")
        #expect(gcloudAccountEmail("dev@example.com") == "dev@example.com")
    }

    @Test func theConfigDirectoryFollowsCloudSDKConfig() {
        let home = ["HOME": "/Users/someone"]
        #expect(ConfigPaths.standard(environment: home).gcloudConfig.path == "/Users/someone/.config/gcloud")
        #expect(ConfigPaths.standard(environment: home.merging(["CLOUDSDK_CONFIG": "~/gcloud-dev"]) { $1 })
            .gcloudConfig.path == "/Users/someone/gcloud-dev")
        #expect(ConfigPaths.standard(environment: home.merging(["CLOUDSDK_CONFIG": "/opt/gcloud"]) { $1 })
            .gcloudConfig.path == "/opt/gcloud")
        #expect(ConfigPaths.standard(environment: home.merging(["CLOUDSDK_CONFIG": ""]) { $1 })
            .gcloudConfig.path == "/Users/someone/.config/gcloud")
    }

    // MARK: What a change means

    @Test func aLargerRowIDIsALoginAtTheFilesTime() {
        let later = seen.addingTimeInterval(600)

        #expect(observe(previous: .present(rowID: 2), current: .present(rowID: 5), modified: later) == .newLogin(at: later))
    }

    @Test func theSameRowIDIsNothing() {
        let later = seen.addingTimeInterval(600)

        #expect(observe(previous: .present(rowID: 2), current: .present(rowID: 2), modified: later) == .noChange)
    }

    @Test func aRowGoneIsALogout() {
        #expect(observe(previous: .present(rowID: 2), current: .missing, modified: seen) == .loggedOut)
    }

    @Test func aRowBackAfterALogoutIsALogin() {
        #expect(observe(previous: .missing, current: .present(rowID: 3), modified: seen) == .newLogin(at: seen))
    }

    @Test func aFirstSightIsOnlyABaseline() {
        #expect(observe(previous: nil, current: .present(rowID: 3), modified: seen) == .noChange)
        #expect(observe(previous: nil, current: .missing, modified: seen) == .noChange)
        #expect(observe(previous: .missing, current: .missing, modified: seen) == .noChange)
    }
}
