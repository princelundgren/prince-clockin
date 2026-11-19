import Foundation
import Testing
import PrinceClockInCore

private let gb = Locale(identifier: "en_GB")

@Suite struct EmptyPanelTests {
    @Test func firstRunSaysWhatDiscoveryFound() {
        let state = emptyPanel(
            aws: ["dev", "prod", "staging"], databricks: [DatabricksProfile(name: "analytics-dev", accountLevel: false)],
            locale: gb)

        #expect(state == EmptyPanel(
            title: "No logins yet",
            message: "Found 4 in your config files: 3 AWS SSO sessions and 1 Databricks profile."))
    }

    @Test func countsAccountProfilesAsTheirOwnKind() {
        let state = emptyPanel(
            aws: ["dev"],
            databricks: [
                DatabricksProfile(name: "analytics-dev", accountLevel: false),
                DatabricksProfile(name: "analytics-prod", accountLevel: false),
                DatabricksProfile(name: "account", accountLevel: true),
            ],
            locale: gb)

        #expect(state.message
            == "Found 4 in your config files: 1 AWS SSO session, 2 Databricks profiles and 1 Databricks account profile.")
    }

    @Test func oneKindAloneIsNotAList() {
        let state = emptyPanel(aws: ["dev"], databricks: [], locale: gb)

        #expect(state.message == "Found 1 in your config files: 1 AWS SSO session.")
    }

    @Test func nothingFoundSaysHowToGetALogin() {
        let state = emptyPanel(aws: [], databricks: [], locale: gb)

        #expect(state == EmptyPanel(
            title: nil,
            message: "No AWS SSO sessions or Databricks profiles in your config files. Log in once with the aws or "
                + "databricks CLI, or add your own command."))
    }
}
