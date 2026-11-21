import Foundation
import Testing
import PrinceClockInCore

private let home = "/Users/someone"
private let seen = at("2026-11-21T09:00:00Z")

/// A config as `oci session authenticate` writes it, for profile `name`.
private func sessionSection(_ name: String, region: String? = "eu-frankfurt-1", sessions: String = "~/.oci/sessions") -> String {
    """
    [\(name)]
    fingerprint=00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00
    key_file=\(sessions)/\(name)/oci_api_key.pem
    tenancy=ocid1.tenancy.oc1..placeholder
    \(region.map { "region=\($0)" } ?? "")
    security_token_file=\(sessions)/\(name)/token

    """
}

@Suite struct OCISessionTests {
    // MARK: Discovery

    @Test func sessionProfilesAreOfferedAndAPIKeyProfilesArent() {
        let text = sessionSection("analytics-dev") + """
            [analytics-prod]
            user=ocid1.user.oc1..placeholder
            fingerprint=00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00
            key_file=~/.oci/oci_api_key.pem
            tenancy=ocid1.tenancy.oc1..placeholder
            region=eu-frankfurt-1

            """ + sessionSection("analytics-test")

        let profiles = discoverOCISessionProfiles(configText: text, home: home)

        #expect(profiles.map(\.name) == ["analytics-dev", "analytics-test"])
        #expect(profiles.first == OCISessionProfile(
            name: "analytics-dev", region: "eu-frankfurt-1",
            securityTokenFile: URL(filePath: "/Users/someone/.oci/sessions/analytics-dev/token")))
    }

    @Test func aProfileWithoutARegionTakesDefaultsAndItsOwnWins() {
        let text = """
            [DEFAULT]
            region=eu-amsterdam-1

            """ + sessionSection("analytics-dev", region: nil) + sessionSection("analytics-prod", region: "eu-frankfurt-1")

        let profiles = discoverOCISessionProfiles(configText: text, home: home)

        #expect(profiles.map(\.region) == ["eu-amsterdam-1", "eu-frankfurt-1"])
    }

    @Test func aProfileWithNoRegionAnywhereHasNone() {
        let profiles = discoverOCISessionProfiles(configText: sessionSection("analytics-dev", region: nil), home: home)

        #expect(profiles.map(\.region) == [nil])
    }

    @Test func aSecurityTokenFileInDefaultIsntInherited() {
        let text = sessionSection("DEFAULT") + """
            [analytics-prod]
            key_file=~/.oci/oci_api_key.pem
            tenancy=ocid1.tenancy.oc1..placeholder

            """

        let profiles = discoverOCISessionProfiles(configText: text, home: home)

        #expect(profiles.map(\.name) == ["DEFAULT"])
    }

    @Test func keysMatchIgnoringCaseAsConfigparserReadsThem() {
        let text = """
            [analytics-dev]
            Region=eu-frankfurt-1
            Security_Token_File=/Users/someone/.oci/sessions/analytics-dev/token
            """

        #expect(discoverOCISessionProfiles(configText: text, home: home) == [ociProfile("analytics-dev")])
    }

    @Test func aRepeatedSectionAddsToTheFirstAndIsListedOnce() {
        let text = """
            [analytics-dev]
            region=eu-frankfurt-1

            [analytics-dev]
            security_token_file=/Users/someone/.oci/sessions/analytics-dev/token
            """

        #expect(discoverOCISessionProfiles(configText: text, home: home) == [ociProfile("analytics-dev")])
    }

    @Test func aRelativeTokenFileOrANameOCIRefusesIsntOffered() {
        let text = """
            [analytics-dev]
            security_token_file=sessions/analytics-dev/token

            [analytics dev]
            security_token_file=/Users/someone/.oci/sessions/analytics dev/token

            [..]
            security_token_file=/Users/someone/.oci/sessions/x/token

            [ops@example.com]
            security_token_file=/Users/someone/.oci/sessions/ops@example.com/token
            """

        #expect(discoverOCISessionProfiles(configText: text, home: home).map(\.name) == ["ops@example.com"])
    }

    @Test func aMissingConfigOffersNothing() {
        #expect(discoverOCISessionProfiles(configText: nil, home: home) == [])
    }

    @Test func theConfigComesFromOCICLIConfigFileWithATildeExpanded() {
        let standard = ConfigPaths.standard(environment: ["HOME": home])
        let overridden = ConfigPaths.standard(environment: ["HOME": home, "OCI_CLI_CONFIG_FILE": "~/work/oci-config"])
        let empty = ConfigPaths.standard(environment: ["HOME": home, "OCI_CLI_CONFIG_FILE": ""])

        #expect(standard.ociConfig.path == "/Users/someone/.oci/config")
        #expect(overridden.ociConfig.path == "/Users/someone/work/oci-config")
        #expect(empty.ociConfig.path == "/Users/someone/.oci/config")
    }

    @Test func theSessionFolderHoldsThePublicKeyAndSitsInTheTokenLocation() {
        let profile = ociProfile("analytics-dev")

        #expect(profile.publicKeyFile.path == "/Users/someone/.oci/sessions/analytics-dev/oci_api_key_public.pem")
        #expect(profile.tokenLocation.path == "/Users/someone/.oci/sessions")
    }

    // MARK: Reading the config and the public keys

    @Test func readingStatsEachPublicKeyWithoutOpeningIt() throws {
        let directory = try makeTemporaryDirectory()
        let sessions = directory.appending(path: "sessions")
        let config = directory.appending(path: "config")
        try (sessionSection("analytics-dev", sessions: sessions.path) + sessionSection("analytics-prod", sessions: sessions.path))
            .write(to: config, atomically: true, encoding: .utf8)
        let key = sessions.appending(path: "analytics-dev/oci_api_key_public.pem")
        try FileManager.default.createDirectory(at: key.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "public key placeholder".write(to: key, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: seen.addingTimeInterval(0.6), .posixPermissions: 0o000], ofItemAtPath: key.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path) }

        let read = try readOCIConfig(at: config, home: home)

        #expect(read.file == config)
        #expect(read.publicKeyState(profile: "analytics-dev") == .present(modified: seen))
        #expect(read.publicKeyState(profile: "analytics-prod") == .missing)
        #expect(read.publicKeyState(profile: "analytics-test") == .missing)
    }

    @Test func aMissingConfigHasNoProfiles() throws {
        let missing = try makeTemporaryDirectory().appending(path: "config")

        #expect(try readOCIConfig(at: missing, home: home).profiles == [])
    }

    @Test func aConfigThatIsntTextCantBeRead() throws {
        let file = try makeTemporaryDirectory().appending(path: "config")
        try Data([0xFF, 0xFE, 0x00, 0xD8]).write(to: file)

        #expect(throws: OCIConfigError(fileName: "config")) { try readOCIConfig(at: file, home: home) }
    }

    @Test func aProfileWhoseKeyFileCantBeStatedHasNoState() {
        let config = OCIConfig(file: FakeOCIReader.configFile, profiles: [ociProfile("analytics-dev")], publicKeys: [:])

        #expect(config.publicKeyState(profile: "analytics-dev") == nil)
    }

    @Test func aWatchOfTheConfigsFolderReactsToTheConfigOnly() {
        #expect(ociConfigFileNames(configFile: URL(filePath: "/Users/someone/work/oci-config")) == ["oci-config"])
    }

    // MARK: Detection

    @Test func aFirstSightIsOnlyABaseline() {
        #expect(observeOCIPublicKey(previous: nil, current: .present(modified: seen)) == .noChange)
        #expect(observeOCIPublicKey(previous: nil, current: .missing) == .noChange)
    }

    @Test func aNewerPublicKeyIsALoginAtItsDate() {
        let later = seen.addingTimeInterval(3600)

        #expect(observeOCIPublicKey(previous: .present(modified: seen), current: .present(modified: later))
            == .newLogin(at: later))
    }

    @Test func theSameOrAnOlderPublicKeyChangesNothing() {
        #expect(observeOCIPublicKey(previous: .present(modified: seen), current: .present(modified: seen)) == .noChange)
        #expect(observeOCIPublicKey(
            previous: .present(modified: seen), current: .present(modified: seen.addingTimeInterval(-60))) == .noChange)
    }

    @Test func aPublicKeyGoneIsALogoutAndItsReturnALogin() {
        #expect(observeOCIPublicKey(previous: .present(modified: seen), current: .missing) == .loggedOut)
        #expect(observeOCIPublicKey(previous: .missing, current: .present(modified: seen)) == .newLogin(at: seen))
        #expect(observeOCIPublicKey(previous: .missing, current: .missing) == .noChange)
    }

    // MARK: Login

    @Test func loginAuthenticatesWhereTheConfigPoints() throws {
        let config = OCIConfig(file: FakeOCIReader.configFile, profiles: [ociProfile("analytics-dev")], publicKeys: [:])

        let command = try ociLoginCommand(profile: "analytics-dev", config: config).get()

        #expect(command == LoginCommand(executable: "oci", arguments: [
            "session", "authenticate", "--profile-name=analytics-dev", "--region=eu-frankfurt-1",
            "--config-location=/Users/someone/.oci/config", "--token-location=/Users/someone/.oci/sessions",
        ]))
    }

    @Test func aFlagLikeProfileNameStaysInsideItsArgument() throws {
        let config = OCIConfig(file: FakeOCIReader.configFile, profiles: [ociProfile("--no-browser")], publicKeys: [:])

        let arguments = try ociLoginCommand(profile: "--no-browser", config: config).get().arguments

        #expect(arguments.contains("--profile-name=--no-browser"))
        #expect(!arguments.contains("--no-browser"))
    }

    @Test func aProfileWithNoRegionCantLogIn() {
        let config = OCIConfig(
            file: FakeOCIReader.configFile, profiles: [ociProfile("analytics-dev", region: nil)], publicKeys: [:])

        #expect(ociLoginCommand(profile: "analytics-dev", config: config) == .failure(.noRegion))
        #expect(LoginFailure.ociProfile(.noRegion).message
            == "The profile has no region in the OCI config file; add one, or oci would ask for it")
    }

    @Test func aProfileGoneOrAnUnreadableConfigCantLogIn() {
        let config = OCIConfig(file: FakeOCIReader.configFile, profiles: [], publicKeys: [:])

        #expect(ociLoginCommand(profile: "analytics-dev", config: config) == .failure(.notASessionProfile))
        #expect(ociLoginCommand(profile: "analytics-dev", config: nil) == .failure(.configUnreadable))
    }
}
