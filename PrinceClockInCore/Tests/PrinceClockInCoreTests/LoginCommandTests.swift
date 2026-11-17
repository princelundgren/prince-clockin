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

    @Test func customKindHasNoCommand() {
        #expect(loginCommand(for: .custom(command: "echo hi")) == nil)
    }
}
