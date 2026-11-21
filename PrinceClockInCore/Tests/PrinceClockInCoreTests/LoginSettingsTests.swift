import Foundation
import Testing
import PrinceClockInCore

private let hour: TimeInterval = 3600
private let now = at("2026-11-19T12:00:00Z")
private let british = Locale(identifier: "en_GB")
private let home = URL(filePath: "/Users/someone")
private let paths = ConfigPaths(
    awsConfig: URL(filePath: "/Users/someone/.aws/config"),
    databricksConfig: URL(filePath: "/Users/someone/.databrickscfg"),
    gcloudConfig: URL(filePath: "/Users/someone/.config/gcloud"),
    azureConfig: URL(filePath: "/Users/someone/.azure"))

private var stockholm: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = british
    calendar.timeZone = TimeZone(identifier: "Europe/Stockholm")!
    return calendar
}

private func aws(_ name: String = "qa", sessionLength: TimeInterval? = 8 * hour) -> Login {
    Login(displayName: name, kind: .awsSSOSession(name: name), sessionLength: sessionLength)
}

private func databricks(
    _ name: String = "analytics-dev", accountLevel: Bool = false, sessionLength: TimeInterval? = 72 * hour,
    lastCheck: DatabricksCheckRecord? = nil
) -> Login {
    Login(
        displayName: name, kind: .databricksProfile(name: name, accountLevel: accountLevel),
        sessionLength: sessionLength, lastDatabricksCheck: lastCheck)
}

private func custom(command: String? = "openconnect vpn.example.com") -> Login {
    Login(displayName: "vpn", kind: .custom(command: command), sessionLength: 12 * hour)
}

private func subtitle(_ login: Login) -> String {
    loginRowSubtitle(for: login, now: now, locale: british, calendar: stockholm)
}

private func form(_ login: Login) -> LoginSettingsForm {
    loginSettingsForm(for: login, paths: paths, home: home, now: now, locale: british, calendar: stockholm)
}

private func lengthNote(_ kind: LoginKind, choice: SessionLengthChoice = .length(8 * hour)) -> String {
    sessionLengthNote(for: kind, choice: choice)
}

@Suite struct LoginSettingsTests {
    // MARK: The list's rows

    @Test func eachKindHasItsSymbol() {
        #expect(loginKindSymbolName(.awsSSOSession(name: "qa")) == "cloud")
        #expect(loginKindSymbolName(.databricksProfile(name: "analytics-dev", accountLevel: false))
            == "square.stack.3d.up")
        #expect(loginKindSymbolName(.databricksProfile(name: "account", accountLevel: true)) == "square.stack.3d.up")
        #expect(loginKindSymbolName(.custom(command: nil)) == "terminal")
        #expect(loginKindSymbolName(.gcloudAccount(account: "dev@example.com")) == "person.badge.key")
    }

    @Test func anAzureTenantShowsItsKindCheckAndProfile() {
        let checked = DatabricksCheckRecord(at: now.addingTimeInterval(-hour), result: .invalid)
        let dev = Login(
            displayName: "Contoso Dev", kind: .azureTenant(user: "dev@example.com", tenant: "00000000-0000-0000-0000-000000000001"),
            lastDatabricksCheck: checked)

        #expect(loginKindSymbolName(dev.kind) == "building.2")
        #expect(subtitle(dev) == "Azure CLI tenant · No timer · Checked 12:00 · invalid")
        #expect(form(dev).source == LoginSource(
            label: "Tenant", value: "00000000-0000-0000-0000-000000000001 for dev@example.com", note: "In ~/.azure.",
            file: paths.azureConfig))
        #expect(form(dev).lastCheck == LastCheck(text: "Checked 12:00 · invalid", note: nil))
        var unchecked = dev
        unchecked.lastDatabricksCheck = nil
        #expect(form(unchecked).lastCheck == LastCheck(text: "Not checked yet", note: nil))
    }

    @Test func aGcloudAccountShowsItsKindCheckAndStore() {
        let checked = DatabricksCheckRecord(at: now.addingTimeInterval(-hour), result: .valid)
        let dev = Login(
            displayName: "dev@example.com", kind: .gcloudAccount(account: "dev@example.com#example.goog"),
            lastDatabricksCheck: checked)

        #expect(subtitle(dev) == "gcloud account · No timer · Checked 12:00 · valid")
        #expect(form(dev).source == LoginSource(
            label: "Account", value: "dev@example.com#example.goog", note: "In ~/.config/gcloud.",
            file: paths.gcloudConfig))
        #expect(form(dev).lastCheck == LastCheck(text: "Checked 12:00 · valid", note: nil))
        var unchecked = dev
        unchecked.lastDatabricksCheck = nil
        #expect(form(unchecked).lastCheck == LastCheck(text: "Not checked yet", note: nil))
    }

    @Test func aSubtitleHasTheKindAndTheSessionLength() {
        #expect(subtitle(aws()) == "AWS SSO session · 8-hour session")
        #expect(subtitle(custom()) == "Custom login · 12-hour session")
    }

    @Test func anUnknownSessionLengthReadsNoTimer() {
        #expect(subtitle(aws(sessionLength: nil)) == "AWS SSO session · No timer")
    }

    @Test func aDatabricksSubtitleEndsWithItsLastCheck() {
        let checked = databricks(lastCheck: DatabricksCheckRecord(at: at("2026-11-19T13:02:00Z"), result: .valid))

        #expect(subtitle(checked) == "Databricks profile · 3-day session · Checked 14:02 · valid")
    }

    @Test func eachCheckResultHasItsWord() {
        let checkedAt = at("2026-11-19T13:02:00Z")
        let invalid = databricks(lastCheck: DatabricksCheckRecord(at: checkedAt, result: .invalid))
        let couldnt = databricks(lastCheck: DatabricksCheckRecord(at: checkedAt, result: .couldntCheck))

        #expect(subtitle(invalid).hasSuffix("Checked 14:02 · invalid"))
        #expect(subtitle(couldnt).hasSuffix("Checked 14:02 · couldn't check"))
    }

    @Test func aProfileNeverCheckedHasNoCheckInItsSubtitle() {
        #expect(subtitle(databricks()) == "Databricks profile · 3-day session")
    }

    @Test func anAccountProfileSaysNotChecked() {
        #expect(subtitle(databricks("account", accountLevel: true, sessionLength: 24 * hour))
            == "Databricks account profile · 1-day session · Not checked")
    }

    @Test func aCheckOnAnotherDayGivesItsDay() {
        let checked = databricks(lastCheck: DatabricksCheckRecord(at: at("2026-01-05T13:02:00Z"), result: .valid))

        #expect(subtitle(checked).hasSuffix("Checked 5 Jan 2026 at 14:02 · valid"))
    }

    // MARK: The selected login's form

    @Test func anAWSSessionsSourceIsItsSessionInTheConfigFile() {
        let source = form(aws()).source

        #expect(source == LoginSource(
            label: "SSO session", value: "qa", note: "In ~/.aws/config.", file: paths.awsConfig))
    }

    @Test func aDatabricksProfilesSourceIsItsProfileInTheConfigFile() {
        #expect(form(databricks()).source
            == LoginSource(
                label: "Profile", value: "analytics-dev", note: "In ~/.databrickscfg.", file: paths.databricksConfig))
    }

    @Test func theSourceNamesTheCLIsNameNotTheDisplayName() {
        var renamed = aws()
        renamed.displayName = "QA account"

        #expect(form(renamed).source?.value == "qa")
    }

    @Test func aConfigFileOutsideHomeIsShownInFull() {
        let elsewhere = ConfigPaths(
            awsConfig: URL(filePath: "/etc/aws/config"),
            databricksConfig: URL(filePath: "/Users/someoneelse/.databrickscfg"),
            gcloudConfig: URL(filePath: "/Users/someoneelse/.config/gcloud"),
            azureConfig: URL(filePath: "/Users/someoneelse/.azure"))

        let awsForm = loginSettingsForm(
            for: aws(), paths: elsewhere, home: home, now: now, locale: british, calendar: stockholm)
        let databricksForm = loginSettingsForm(
            for: databricks(), paths: elsewhere, home: home, now: now, locale: british, calendar: stockholm)

        #expect(awsForm.source?.note == "In /etc/aws/config.")
        #expect(databricksForm.source?.note == "In /Users/someoneelse/.databrickscfg.")
        #expect(awsForm.source?.file == elsewhere.awsConfig)
    }

    @Test func aCustomLoginHasNoSourceAndTheCommandsNote() {
        let customForm = form(custom())

        #expect(customForm.source == nil)
        #expect(customForm.lastCheck == nil)
        #expect(customForm.commandNote
            == "The command runs in Terminal and is saved as plain text, so don't put a secret in it.")
    }

    @Test func onlyACustomLoginHasTheCommandsNote() {
        #expect(form(aws()).commandNote == nil)
        #expect(form(databricks()).commandNote == nil)
    }

    @Test func aDatabricksProfileShowsItsLastCheck() {
        let checkedAt = at("2026-11-19T13:02:00Z")
        let checked = databricks(lastCheck: DatabricksCheckRecord(at: checkedAt, result: .couldntCheck))

        #expect(form(checked).lastCheck == LastCheck(text: "Checked 14:02 · couldn't check", note: nil))
        #expect(form(databricks()).lastCheck == LastCheck(text: "Not checked yet", note: nil))
        #expect(form(aws()).lastCheck == nil)
    }

    @Test func anAccountProfileSaysNotCheckedAndWhy() {
        let account = form(databricks("account", accountLevel: true))

        #expect(account.lastCheck == LastCheck(
            text: "Not checked",
            note: "The Databricks CLI can't check an account profile, so this login runs on its timer alone."))
    }

    @Test func renamingALoginLeavesItsCLIAsItIs() {
        let gcloud = Login(displayName: "dev", kind: .gcloudAccount(account: "dev@example.com"))
        let azure = Login(displayName: "dev", kind: .azureTenant(user: "dev@example.com", tenant: "contoso"))

        #expect(form(aws()).nameNote == "Only changes the name in PrinceClockIn, not in your config.")
        #expect(form(databricks()).nameNote == "Only changes the name in PrinceClockIn, not in your config.")
        #expect(form(gcloud).nameNote == "Only changes the name in PrinceClockIn, not in gcloud.")
        #expect(form(azure).nameNote == "Only changes the name in PrinceClockIn, not in the Azure CLI.")
    }

    @Test func aCustomLoginsNameHasNoNote() {
        #expect(form(custom()).nameNote == nil)
    }

    // MARK: Session length's note

    @Test func theSessionLengthNoteSaysWhatTheLengthIsFor() {
        #expect(lengthNote(.awsSSOSession(name: "qa")).hasPrefix(
            "How long a sign-in lasts before you must log in again. The CLI doesn't report it, so PrinceClockIn"
                + " counts down from it and notifies you before it ends."))
    }

    @Test func aCustomLoginsSessionLengthNoteMentionsNoCLI() {
        #expect(lengthNote(.custom(command: nil))
            == "How long a sign-in lasts before you must log in again. PrinceClockIn counts down from it and"
                + " notifies you before it ends.")
    }

    @Test func eachCLIKindSaysWhoSetsItsLength() {
        #expect(lengthNote(.awsSSOSession(name: "qa")).hasSuffix(
            "Your admin sets it in IAM Identity Center; its default is 8 hours."))
        #expect(lengthNote(.databricksProfile(name: "analytics-dev", accountLevel: false)).hasSuffix(
            "Your account admin sets it in the account's OAuth token policy."))
        #expect(lengthNote(.gcloudAccount(account: "dev@example.com")).hasSuffix(
            "Your Google Workspace admin sets it in Google Cloud session control."))
        #expect(lengthNote(.azureTenant(user: "dev@example.com", tenant: "contoso")).hasSuffix(
            "Your admin sets it as the sign-in frequency in Entra Conditional Access."))
    }

    @Test func noTimerSaysThereIsNoCountdownOrNotification() {
        #expect(lengthNote(.awsSSOSession(name: "qa"), choice: .noTimer)
            .hasSuffix("With No timer, this login has no countdown and no notification."))
        #expect(!lengthNote(.awsSSOSession(name: "qa")).contains("No timer"))
    }

    /// Custom… on a login with no timer leaves its stored length unset until the hours are stored.
    @Test func customChosenOnALoginWithNoTimerDropsTheNoTimerSentence() {
        #expect(!lengthNote(.awsSSOSession(name: "qa"), choice: .custom).contains("No timer"))
    }
}
