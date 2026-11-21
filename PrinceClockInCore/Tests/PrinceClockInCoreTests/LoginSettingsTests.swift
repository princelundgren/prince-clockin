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
    azureConfig: URL(filePath: "/Users/someone/.azure"),
    ociConfig: URL(filePath: "/Users/someone/.oci/config"))

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

    @Test func anOCISessionProfileShowsItsKindAndProfileAndIsNotChecked() {
        let dev = Login(
            displayName: "analytics-dev", kind: .ociSessionProfile(name: "analytics-dev"), sessionLength: 24 * hour)

        #expect(loginKindSymbolName(dev.kind) == "server.rack")
        #expect(subtitle(dev) == "OCI session profile · 1-day session · Not checked")
        #expect(form(dev).source == LoginSource(label: "Profile", value: "analytics-dev in ~/.oci/config"))
        #expect(form(dev).lastCheck == LastCheck(text: "Not checked", note: ociSessionNote))
    }

    @Test func anAzureTenantShowsItsKindCheckAndProfile() {
        let checked = DatabricksCheckRecord(at: now.addingTimeInterval(-hour), result: .invalid)
        let dev = Login(
            displayName: "Contoso Dev", kind: .azureTenant(user: "dev@example.com", tenant: "00000000-0000-0000-0000-000000000001"),
            lastDatabricksCheck: checked)

        #expect(loginKindSymbolName(dev.kind) == "building.2")
        #expect(subtitle(dev) == "Azure CLI tenant · No timer · Checked 12:00 · invalid")
        #expect(form(dev).source == LoginSource(label: "Tenant", value: "00000000-0000-0000-0000-000000000001 for dev@example.com in ~/.azure"))
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
        #expect(form(dev).source == LoginSource(label: "Account", value: "dev@example.com#example.goog in ~/.config/gcloud"))
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

        #expect(source == LoginSource(label: "SSO session", value: "qa in ~/.aws/config"))
    }

    @Test func aDatabricksProfilesSourceIsItsProfileInTheConfigFile() {
        #expect(form(databricks()).source == LoginSource(label: "Profile", value: "analytics-dev in ~/.databrickscfg"))
    }

    @Test func theSourceNamesTheCLIsNameNotTheDisplayName() {
        var renamed = aws()
        renamed.displayName = "QA account"

        #expect(form(renamed).source?.value == "qa in ~/.aws/config")
    }

    @Test func aConfigFileOutsideHomeIsShownInFull() {
        let elsewhere = ConfigPaths(
            awsConfig: URL(filePath: "/etc/aws/config"),
            databricksConfig: URL(filePath: "/Users/someoneelse/.databrickscfg"),
            gcloudConfig: URL(filePath: "/Users/someoneelse/.config/gcloud"),
            azureConfig: URL(filePath: "/Users/someoneelse/.azure"),
            ociConfig: URL(filePath: "/Users/someoneelse/.oci/config"))

        let awsForm = loginSettingsForm(
            for: aws(), paths: elsewhere, home: home, now: now, locale: british, calendar: stockholm)
        let databricksForm = loginSettingsForm(
            for: databricks(), paths: elsewhere, home: home, now: now, locale: british, calendar: stockholm)

        #expect(awsForm.source?.value == "qa in /etc/aws/config")
        #expect(databricksForm.source?.value == "analytics-dev in /Users/someoneelse/.databrickscfg")
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

    @Test func theNameIsOnlyWhatTheAppShows() {
        #expect(form(aws()).nameNote
            == "The name is only what PrinceClockIn shows; the SSO session's name in your config stays as it is.")
        #expect(form(databricks()).nameNote
            == "The name is only what PrinceClockIn shows; the profile's name in your config stays as it is.")
        #expect(form(custom()).nameNote == "The name is only what PrinceClockIn shows.")
    }
}
