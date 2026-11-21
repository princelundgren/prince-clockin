import Foundation
import Testing
import PrinceClockInCore

private let gb = Locale(identifier: "en_GB")

@Suite struct EmptyPanelTests {
    @Test func firstRunSaysWhatDiscoveryFound() {
        let state = emptyPanel(
            aws: ["dev", "prod", "staging"], databricks: [DatabricksProfile(name: "analytics-dev", accountLevel: false)],
            gcloud: [], azure: [], locale: gb)

        #expect(state == EmptyPanel(message: "Found 3 AWS SSO sessions and 1 Databricks profile in your config files."))
    }

    @Test func countsAccountProfilesAsTheirOwnKind() {
        let state = emptyPanel(
            aws: ["dev"],
            databricks: [
                DatabricksProfile(name: "analytics-dev", accountLevel: false),
                DatabricksProfile(name: "analytics-prod", accountLevel: false),
                DatabricksProfile(name: "account", accountLevel: true),
            ],
            gcloud: [],
            azure: [],
            locale: gb)

        #expect(state.message
            == "Found 1 AWS SSO session, 2 Databricks profiles and 1 Databricks account profile in your config files.")
    }

    @Test func countsGcloudAccounts() {
        let state = emptyPanel(
            aws: ["dev"], databricks: [], gcloud: ["dev@example.com", "ops@example.com#example.goog"], azure: [],
            locale: gb)

        #expect(state.message == "Found 1 AWS SSO session and 2 gcloud accounts in your config files.")
    }

    @Test func countsAzureCLITenants() {
        let tenant = AzureTenant(
            account: AzureAccount(user: "dev@example.com", tenant: "00000000-0000-0000-0000-000000000001"), displayName: "Contoso Dev")

        let state = emptyPanel(aws: [], databricks: [], gcloud: ["dev@example.com"], azure: [tenant], locale: gb)

        #expect(state.message == "Found 1 gcloud account and 1 Azure CLI tenant in your config files.")
    }

    @Test func oneKindAloneIsNotAList() {
        let state = emptyPanel(aws: ["dev"], databricks: [], gcloud: [], azure: [], locale: gb)

        #expect(state.message == "Found 1 AWS SSO session in your config files.")
    }

    @Test func nothingFoundSaysHowToGetALogin() {
        let state = emptyPanel(aws: [], databricks: [], gcloud: [], azure: [], locale: gb)

        #expect(state == EmptyPanel(
            message: "No AWS SSO sessions, Databricks profiles, gcloud accounts or Azure CLI tenants in your config "
                + "files. Log in once with the aws, databricks, gcloud or az CLI, or add your own command."))
    }
}
