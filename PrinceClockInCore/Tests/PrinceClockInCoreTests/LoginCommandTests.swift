import Testing
import PrinceClockInCore

@Suite struct LoginCommandTests {
    @Test func awsCommandPassesNameAsOneArgument() {
        let command = loginCommand(for: .awsSSOSession(name: "dev; rm -rf ~"))
        #expect(command?.executable == "aws")
        #expect(command?.arguments.last == "--sso-session=dev; rm -rf ~")
        #expect(command?.arguments.count == 3)
    }

    @Test func flagLikeNameStaysInsideItsArgument() {
        let command = loginCommand(for: .databricksProfile(name: "--debug", accountLevel: false))
        #expect(command == LoginCommand(executable: "databricks", arguments: ["auth", "login", "--profile=--debug"]))
        #expect(command?.arguments.contains("--debug") == false)
    }

    @Test func gcloudLogsInToTheAccountsEmailWithForce() {
        #expect(loginCommand(for: .gcloudAccount(account: "dev@example.com")) == LoginCommand(
            executable: "gcloud", arguments: ["auth", "login", "--force", "--account=dev@example.com"]))
        #expect(loginCommand(for: .gcloudAccount(account: "dev@example.com#example.goog")) == LoginCommand(
            executable: "gcloud", arguments: ["auth", "login", "--force", "--account=dev@example.com"]))
    }

    @Test func aFlagLikeGcloudAccountStaysInsideItsArgument() {
        #expect(loginCommand(for: .gcloudAccount(account: "--verbosity=debug"))?.arguments
            == ["auth", "login", "--force", "--account=--verbosity=debug"])
    }

    @Test func azureLogsInToTheTenant() {
        #expect(loginCommand(for: .azureTenant(user: "dev@example.com", tenant: "00000000-0000-0000-0000-000000000001")) == LoginCommand(
            executable: "az", arguments: ["login", "--tenant=00000000-0000-0000-0000-000000000001", "--allow-no-subscriptions"]))
    }

    @Test func aFlagLikeAzureTenantStaysInsideItsArgument() {
        #expect(loginCommand(for: .azureTenant(user: "dev@example.com", tenant: "--use-device-code"))?.arguments
            == ["login", "--tenant=--use-device-code", "--allow-no-subscriptions"])
    }

    @Test func customKindHasNoCommand() {
        #expect(loginCommand(for: .custom(command: "echo hi")) == nil)
    }
}
