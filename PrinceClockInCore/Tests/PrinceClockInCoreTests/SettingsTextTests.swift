import Foundation
import Testing
import PrinceClockInCore

private let minute: TimeInterval = 60

@Suite struct SettingsTextTests {
    // MARK: Duration pop-ups

    @Test func eachSettingsDefaultIsOnItsPopUpsList() {
        #expect(listedNotificationLeadTimes.contains(Settings.defaultNotificationLeadTime))
        #expect(listedLoginTimeouts.contains(Settings.defaultLoginTimeout))
    }

    @Test func aListedDurationShowsTheListAsItIs() {
        #expect(durationOptions(listedLoginTimeouts, showing: 10 * minute) == listedLoginTimeouts)
    }

    @Test func anUnlistedStoredDurationIsAddedInOrderSoItStaysShown() {
        #expect(
            durationOptions(listedNotificationLeadTimes, showing: 45 * minute)
                == [5, 10, 15, 30, 45, 60, 120].map { $0 * minute })
    }

    @Test func aStoredDurationAboveTheListComesLast() {
        #expect(durationOptions(listedLoginTimeouts, showing: 30 * minute) == [2, 5, 10, 15, 30].map { $0 * minute })
    }

    @Test func everyListedLoginTimeoutRunsAsListed() {
        for timeout in listedLoginTimeouts {
            #expect(Settings(loginTimeout: timeout).appliedLoginTimeout == timeout)
        }
    }

    @Test func aStoredLoginTimeoutOutsideTheRangeRunsAtTheNearestBound() {
        #expect(Settings(loginTimeout: 1e30).appliedLoginTimeout == 24 * 60 * minute)
        #expect(Settings(loginTimeout: 0).appliedLoginTimeout == 2 * minute)
        #expect(Settings(loginTimeout: -300).appliedLoginTimeout == 2 * minute)
        #expect(Settings(loginTimeout: 45 * minute).appliedLoginTimeout == 45 * minute)
    }

    @Test func aStoredLoginTimeoutThatIsNotFiniteRunsAtTheDefault() {
        for timeout in [TimeInterval.nan, .infinity, -.infinity] {
            #expect(Settings(loginTimeout: timeout).appliedLoginTimeout == Settings.defaultLoginTimeout)
        }
    }


    // MARK: Presets

    @Test func aNewPresetIsNamedNewPresetWhenThatNameIsFree() {
        #expect(newPresetName(existingNames: ["Morning"]) == "New preset")
    }

    @Test func aNewPresetTakesTheFirstFreeNumber() {
        #expect(newPresetName(existingNames: ["New preset"]) == "New preset 2")
        #expect(newPresetName(existingNames: ["New preset", "New preset 2", "New preset 4"]) == "New preset 3")
    }

    @Test func minusHelpTagNamesTheSelectedPreset() {
        #expect(removePresetHelp(for: Preset(name: "Morning", loginIDs: [])) == "Remove Morning.")
        #expect(removePresetHelp(for: nil) == "Remove the selected preset.")
    }

    // MARK: Notifications

    @Test func notificationsOnSayNoMore() {
        #expect(notificationsSetting(areOff: false) == NotificationsSetting(state: "On", note: nil))
    }

    @Test func notificationsOffSayOnlyTheMenuBarShowsIt() {
        #expect(notificationsSetting(areOff: true) == NotificationsSetting(
            state: "Off", note: "With notifications off, only the menu bar shows that a login is about to expire."))
    }

    // MARK: General

    @Test func launchAtLoginOffOrOnSaysNoMore() {
        #expect(launchAtLoginSetting(status: .off, failure: nil) == LaunchAtLoginSetting(isOn: false, note: nil))
        #expect(launchAtLoginSetting(status: .on, failure: nil) == LaunchAtLoginSetting(isOn: true, note: nil))
    }

    @Test func launchAtLoginAwaitingApprovalIsOnAndPointsToLoginItems() {
        #expect(launchAtLoginSetting(status: .needsApproval, failure: nil) == LaunchAtLoginSetting(
            isOn: true, note: .needsApproval("Needs your approval in System Settings → General → Login Items.")))
    }

    @Test func aFailedTurnOnSaysWhy() {
        let failure = LaunchAtLoginFailure(turningOn: true, reason: "The operation couldn’t be completed.")

        #expect(launchAtLoginSetting(status: .notFound, failure: failure) == LaunchAtLoginSetting(
            isOn: false, note: .failed("Couldn't turn on launch at login. The operation couldn’t be completed.")))
    }

    @Test func aFailedTurnOffSaysWhy() {
        let failure = LaunchAtLoginFailure(turningOn: false, reason: "Operation not permitted.")

        #expect(launchAtLoginSetting(status: .on, failure: failure) == LaunchAtLoginSetting(
            isOn: true, note: .failed("Couldn't turn off launch at login. Operation not permitted.")))
    }

    @Test func aFailureGoesOnceTheSystemShowsTheChangeHappened() {
        let failedOn = LaunchAtLoginFailure(turningOn: true, reason: "Try again.")
        let failedOff = LaunchAtLoginFailure(turningOn: false, reason: "Try again.")

        #expect(launchAtLoginSetting(status: .on, failure: failedOn).note == nil)
        #expect(launchAtLoginSetting(status: .off, failure: failedOff).note == nil)
    }

    @Test func approvalWinsOverAFailedTurnOn() {
        let failure = LaunchAtLoginFailure(turningOn: true, reason: "Operation not permitted.")

        #expect(launchAtLoginSetting(status: .needsApproval, failure: failure).note
            == .needsApproval("Needs your approval in System Settings → General → Login Items."))
    }

    // MARK: About

    @Test func theVersionIsTheMarketingVersionThenTheBuildNumber() {
        #expect(versionText(marketingVersion: "1.0.0", build: "42") == "v1.0.0 (42)")
    }
}
