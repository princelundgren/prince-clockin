import Foundation
import Testing
import PrinceClockInCore

@Suite struct DiscoveryTests {
    @Test func findsSSOSessionsNotProfiles() {
        let config = """
            [profile dev]
            sso_session = dev
            region = eu-north-1

            [sso-session dev]
            sso_start_url = https://example.awsapps.com/start
            sso_region = eu-north-1

            [sso-session prod]
            sso_start_url = https://example.awsapps.com/start
            """
        #expect(discoverAWSSessions(configText: config) == ["dev", "prod"])
    }

    @Test func findsOnlyDatabricksCliProfiles() {
        let config = """
            [analytics-dev]
            host = https://example.cloud.databricks.com
            auth_type = databricks-cli

            [legacy]
            host = https://example.cloud.databricks.com
            auth_type = pat

            [ci]
            auth_type = oauth-m2m

            [account]
            host = https://accounts.example.cloud.databricks.com
            account_id = 00000000-0000-0000-0000-000000000000
            auth_type = databricks-cli
            """
        #expect(discoverDatabricksProfiles(configText: config) == [
            DatabricksProfile(name: "analytics-dev", accountLevel: false),
            DatabricksProfile(name: "account", accountLevel: true),
        ])
    }

    @Test func missingConfigGivesEmpty() {
        #expect(discoverAWSSessions(configText: nil).isEmpty)
        #expect(discoverDatabricksProfiles(configText: nil).isEmpty)
    }

    @Test func emptyConfigGivesEmpty() {
        #expect(discoverAWSSessions(configText: "").isEmpty)
        #expect(discoverDatabricksProfiles(configText: "").isEmpty)
    }

    @Test func malformedLinesAreSkipped() {
        let config = """
            [sso-session
            garbage
            [sso-session dev]
            garbage
            sso_region = eu-north-1
            [sso-session prod]
            """
        #expect(discoverAWSSessions(configText: config) == ["dev", "prod"])
        #expect(parseINI(config).first?.values == ["sso_region": "eu-north-1"])
    }

    @Test func commentsAndWhitespaceIgnored() {
        let config = """
            # a comment
            ; another comment

              [sso-session dev]
            sso_region   =   eu-north-1
            # sso_region = ignored

            [profile dev]
            s3 =
                max_concurrent_requests = 10
                addressing_style = path
            region = eu-north-1
            """
        let sections = parseINI(config)
        #expect(sections.map(\.name) == ["sso-session dev", "profile dev"])
        #expect(sections[0].values == ["sso_region": "eu-north-1"])
        #expect(sections[1].values == ["s3": "", "region": "eu-north-1"])
    }

    @Test func indentedKeysAllBelongToTheSection() {
        let config = "[analytics-dev]\n  host = https://example.cloud.databricks.com\n  auth_type = databricks-cli\n"
        #expect(parseINI(config).first?.values.count == 2)
        #expect(discoverDatabricksProfiles(configText: config) == [
            DatabricksProfile(name: "analytics-dev", accountLevel: false)
        ])
    }

    @Test func malformedHeaderClosesThePreviousSection() {
        let config = "[analytics-dev]\nauth_type = databricks-cli\n[broken\nauth_type = databricks-cli\n"
        #expect(parseINI(config).map(\.name) == ["analytics-dev"])
        #expect(parseINI(config).first?.values == ["auth_type": "databricks-cli"])
        #expect(discoverDatabricksProfiles(configText: config).map(\.name) == ["analytics-dev"])
    }

    @Test func inlineCommentsFollowEachCLIsReader() {
        let config = "[analytics-dev]\nhost = https://example.cloud.databricks.com ; note\nauth_type = databricks-cli # login\nsecret = a#b\n"
        let databricks = parseINI(config, stripInlineComments: true).first?.values
        #expect(databricks?["host"] == "https://example.cloud.databricks.com")
        #expect(databricks?["auth_type"] == "databricks-cli")
        #expect(databricks?["secret"] == "a#b")
        #expect(parseINI(config).first?.values["host"] == "https://example.cloud.databricks.com ; note")
        #expect(discoverDatabricksProfiles(configText: config).map(\.name) == ["analytics-dev"])
    }

    @Test func leadingByteOrderMarkIsIgnored() {
        #expect(discoverAWSSessions(configText: "\u{FEFF}[sso-session dev]\nsso_region = eu-north-1\n") == ["dev"])
    }

    @Test func repeatedNamesAreListedOnce() {
        #expect(discoverAWSSessions(configText: "[sso-session dev]\n[sso-session prod]\n[sso-session dev]\n") == ["dev", "prod"])
        let config = "[dev]\nauth_type = databricks-cli\n[dev]\nauth_type = databricks-cli\naccount_id = x\n"
        #expect(discoverDatabricksProfiles(configText: config) == [
            DatabricksProfile(name: "dev", accountLevel: false)
        ])
    }

    @Test func crlfLinesAndEqualsInValuesAreParsed() {
        let config = "[sso-session dev]\r\nsso_start_url = https://example.awsapps.com/start?a=b\r\n"
        let sections = parseINI(config)
        #expect(sections.map(\.name) == ["sso-session dev"])
        #expect(sections.first?.values == ["sso_start_url": "https://example.awsapps.com/start?a=b"])
    }

    @Test func emptyOverrideFallsBackToDefaultAndAWSTildeExpands() {
        let paths = ConfigPaths.standard(environment: [
            "HOME": "/Users/example", "AWS_CONFIG_FILE": "", "DATABRICKS_CONFIG_FILE": "",
        ])
        #expect(paths.awsConfig.path == "/Users/example/.aws/config")
        #expect(paths.databricksConfig.path == "/Users/example/.databrickscfg")
        let tilde = ConfigPaths.standard(environment: ["HOME": "/Users/example", "AWS_CONFIG_FILE": "~/cfg/aws"])
        #expect(tilde.awsConfig.path == "/Users/example/cfg/aws")
    }

    @Test func configPathsHonourEnvironment() {
        let defaults = ConfigPaths.standard(environment: ["HOME": "/Users/example"])
        #expect(defaults.awsConfig.path == "/Users/example/.aws/config")
        #expect(defaults.databricksConfig.path == "/Users/example/.databrickscfg")

        let overridden = ConfigPaths.standard(environment: [
            "HOME": "/Users/example",
            "AWS_CONFIG_FILE": "/etc/aws-config",
            "DATABRICKS_CONFIG_FILE": "~/custom/.databrickscfg",
        ])
        #expect(overridden.awsConfig.path == "/etc/aws-config")
        #expect(overridden.databricksConfig.path == "/Users/example/custom/.databrickscfg")
    }
}
