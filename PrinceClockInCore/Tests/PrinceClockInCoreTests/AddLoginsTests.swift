import Foundation
import Testing
import PrinceClockInCore

private let hour: TimeInterval = 3600
private let british = Locale(identifier: "en_GB")
private let workspace = DatabricksProfile(name: "analytics-dev", accountLevel: false)
private let account = DatabricksProfile(name: "account", accountLevel: true)

@Suite struct AddLoginsTests {
    // MARK: The + menu

    @Test func renamingOrCustomLoginsLeaveTheTrackedConfigNamesAlone() {
        let before = TrackedConfigNames(logins: [
            Login(displayName: "qa", kind: .awsSSOSession(name: "qa")),
            Login(displayName: "vpn", kind: .custom(command: "vpn up")),
        ])
        let after = TrackedConfigNames(logins: [
            Login(displayName: "QA account", kind: .awsSSOSession(name: "qa")),
            Login(displayName: "vpn", kind: .custom(command: "vpn up --fast")),
            Login(displayName: "build", kind: .custom(command: nil)),
        ])

        #expect(before == after)
    }

    @Test func trackingAProfileChangesTheTrackedConfigNames() {
        let before = TrackedConfigNames(logins: [Login(displayName: "qa", kind: .awsSSOSession(name: "qa"))])
        let after = TrackedConfigNames(logins: [
            Login(displayName: "qa", kind: .awsSSOSession(name: "qa")),
            Login(displayName: "analytics-dev", kind: .databricksProfile(name: "analytics-dev", accountLevel: false)),
        ])

        #expect(before != after)
        #expect(after.databricks == ["analytics-dev"])
    }

    @Test func foundLoginsComeUnderTheirHeaderThenCustomLogin() {
        let menu = addMenu(found: (aws: ["qa"], databricks: [workspace]))

        #expect(menu == [
            .header("Found in your config files"),
            .found(.awsSSOSession(name: "qa")),
            .found(.databricksProfile(workspace)),
            .customLogin,
        ])
    }

    @Test func accountProfilesComeAfterWorkspaceProfiles() {
        let menu = addMenu(found: (aws: [], databricks: [account, workspace]))

        #expect(menu == [
            .header("Found in your config files"),
            .found(.databricksProfile(workspace)),
            .found(.databricksProfile(account)),
            .customLogin,
        ])
    }

    @Test func nothingNewSaysSoAboveCustomLogin() {
        let menu = addMenu(found: (aws: [], databricks: []))

        #expect(menu == [.note("No new AWS SSO sessions or Databricks profiles"), .customLogin])
    }

    @Test func whileTheConfigFilesAreReadOnlyCustomLoginIsOffered() {
        #expect(addMenu(found: nil) == [.customLogin])
    }

    @Test func eachItemHasItsTitleAndAFoundLoginItsKind() {
        #expect(AddMenuItem.found(.awsSSOSession(name: "qa")).title == "qa")
        #expect(AddMenuItem.found(.awsSSOSession(name: "qa")).kind == "AWS SSO session")
        #expect(AddMenuItem.found(.databricksProfile(workspace)).kind == "Databricks profile")
        #expect(AddMenuItem.found(.databricksProfile(account)).kind == "Databricks account profile")
        #expect(AddMenuItem.customLogin.title == "Custom Login…")
        #expect(AddMenuItem.customLogin.kind == nil)
    }

    @Test func aFoundAWSSessionIsTrackedWithItsDefaultLength() {
        let login = AddLoginCandidate.awsSSOSession(name: "qa").login()

        #expect(login.displayName == "qa")
        #expect(login.kind == .awsSSOSession(name: "qa"))
        #expect(login.sessionLength == 8 * hour)
    }

    @Test func aFoundWorkspaceProfileIsTrackedWithNoSessionLength() {
        let login = AddLoginCandidate.databricksProfile(workspace).login()

        #expect(login.displayName == "analytics-dev")
        #expect(login.kind == .databricksProfile(name: "analytics-dev", accountLevel: false))
        #expect(login.sessionLength == nil)
    }

    @Test func aFoundAccountProfileIsTrackedWithNoSessionLength() {
        let login = AddLoginCandidate.databricksProfile(account).login()

        #expect(login.displayName == "account")
        #expect(login.kind == .databricksProfile(name: "account", accountLevel: true))
        #expect(login.sessionLength == nil)
    }

    // MARK: −

    @Test func minusAsksFirstForALoginInSeveralPresetsAndNamesThem() {
        let login = Login(displayName: "vpn", kind: .custom(command: nil))
        let other = UUID()
        let presets = [
            Preset(name: "Morning", loginIDs: [other, login.id]),
            Preset(name: "Unrelated", loginIDs: [other]),
            Preset(name: "Night shift", loginIDs: [login.id]),
        ]

        #expect(removeLoginConfirmation(for: login, presets: presets, locale: british) == RemoveLoginConfirmation(
            loginID: login.id, title: "Remove vpn?", message: "It also leaves the presets Morning and Night shift."))
    }

    @Test func minusAsksFirstForALoginInOnePreset() {
        let login = Login(displayName: "vpn", kind: .custom(command: nil))
        let presets = [Preset(name: "Morning", loginIDs: [login.id])]

        #expect(removeLoginConfirmation(for: login, presets: presets, locale: british)?.message
            == "It also leaves the preset Morning.")
    }

    @Test func minusRemovesALoginInNoPresetAtOnce() {
        let login = Login(displayName: "vpn", kind: .custom(command: nil))
        let presets = [Preset(name: "Morning", loginIDs: [UUID()])]

        #expect(removeLoginConfirmation(for: login, presets: presets, locale: british) == nil)
        #expect(removeLoginConfirmation(for: login, presets: [], locale: british) == nil)
    }

    @Test func minusHelpTagNamesTheSelectedLogin() {
        #expect(removeLoginHelp(for: Login(displayName: "vpn", kind: .custom(command: nil))) == "Remove vpn.")
        #expect(removeLoginHelp(for: nil) == "Remove the selected login.")
    }

    // MARK: New custom login

    @Test func aNewCustomLoginNeedsAName() {
        var draft = NewCustomLoginDraft()
        draft.name = "  "

        #expect(draft.check(locale: british) == .needsName)
    }

    @Test func aNewCustomLoginIsTrimmedAndAnEmptyCommandIsNone() throws {
        var draft = NewCustomLoginDraft()
        draft.name = " intranet "
        draft.command = "  "
        draft.sessionLength = .length(12 * hour)

        let login = try #require(draft.check(locale: british).login)

        #expect(login.displayName == "intranet")
        #expect(login.kind == .custom(command: nil))
        #expect(login.sessionLength == 12 * hour)
    }

    @Test func aNewCustomLoginKeepsItsCommandAndStartsWithNoTimer() throws {
        var draft = NewCustomLoginDraft()
        draft.name = "vpn"
        draft.command = " openconnect vpn.example.com\n"

        let login = try #require(draft.check(locale: british).login)

        #expect(draft.sessionLength == .noTimer)
        #expect(login.kind == .custom(command: "openconnect vpn.example.com"))
        #expect(login.sessionLength == nil)
    }

    @Test func aNewCustomLoginsCustomLengthIsReadInHours() throws {
        var draft = NewCustomLoginDraft()
        draft.name = "vpn"
        draft.sessionLength = .custom
        draft.customHours = "36"

        let login = try #require(draft.check(locale: british).login)

        #expect(login.sessionLength == 36 * hour)
    }

    @Test func aNewCustomLoginsCustomLengthIsRefusedAsTheFieldRefusesIt() {
        var draft = NewCustomLoginDraft()
        draft.name = "vpn"
        draft.sessionLength = .custom
        draft.customHours = "9000"

        #expect(draft.check(locale: british) == .refused(.tooLong))
        draft.customHours = "soon"
        #expect(draft.check(locale: british) == .refused(.notANumberOfHours))
    }

    @Test func customWithNoHoursIsRefusedRatherThanMeaningNoTimer() {
        var draft = NewCustomLoginDraft()
        draft.name = "vpn"
        draft.sessionLength = .custom
        draft.customHours = " "

        #expect(draft.check(locale: british) == .refused(.notANumberOfHours))
    }

    @Test func withoutACommandTheFormSaysLogInWaitsForDone() {
        var draft = NewCustomLoginDraft()

        #expect(draft.noCommandNote == "Without a command, Log In waits for you to log in your own way and click Done.")
        draft.command = "openconnect vpn.example.com"
        #expect(draft.noCommandNote == nil)
    }

    // MARK: The prompt after adding

    @Test func thePromptAfterAddingNamesTheLogin() {
        #expect(addedLoginPrompt(name: "qa")
            == "Already logged in to qa? Set its timer now so it can warn you before it expires, or skip and log in "
            + "from the panel later.")
    }
}

private extension NewCustomLoginCheck {
    var login: Login? {
        if case .ready(let login) = self { login } else { nil }
    }
}
