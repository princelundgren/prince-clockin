import Foundation
import Testing
import PrinceClockInCore

private let backup = URL(filePath: "/tmp/state.json.unreadable")

@Suite struct BannersTests {
    @Test func noBannerWhenAllIsWell() {
        #expect(panelBanners(
            setAsideFile: nil, saveFailure: nil, notificationsAreOff: false, isNotificationsBannerDismissed: false
        ).isEmpty)
    }

    @Test func atMostTwoShowHighestFirstAndTheThirdWaits() {
        let all = panelBanners(
            setAsideFile: backup, saveFailure: "The disk is full.", notificationsAreOff: true,
            isNotificationsBannerDismissed: false)
        let afterDismiss = panelBanners(
            setAsideFile: nil, saveFailure: "The disk is full.", notificationsAreOff: true,
            isNotificationsBannerDismissed: false)

        #expect(all == [.stateSetAside(backup: backup), .saveFailed(reason: "The disk is full.")])
        #expect(afterDismiss == [.saveFailed(reason: "The disk is full."), .notificationsOff])
    }

    @Test func notificationsOffShowsUntilDismissed() {
        let shown = panelBanners(
            setAsideFile: nil, saveFailure: nil, notificationsAreOff: true, isNotificationsBannerDismissed: false)
        let dismissed = panelBanners(
            setAsideFile: nil, saveFailure: nil, notificationsAreOff: true, isNotificationsBannerDismissed: true)

        #expect(shown == [.notificationsOff])
        #expect(dismissed.isEmpty)
    }

    @Test func stateSetAsideSaysTheOldFileWasKept() {
        let banner = Banner.stateSetAside(backup: backup)

        #expect(banner.lines == [
            "PrinceClockIn couldn't use its saved logins (the file was unreadable or from a newer version), so it "
                + "started empty. The old file was kept."
        ])
        #expect(banner.actions == [.showInFinder, .dismiss])
        #expect(banner.actions.map(\.title) == ["Show in Finder…", "Dismiss"])
    }

    @Test func saveFailedGivesTheReasonOnItsOwnLine() {
        let banner = Banner.saveFailed(reason: "The disk is full.")

        #expect(banner.lines == [
            "Your changes couldn't be saved", "The disk is full.", "They'll be lost when PrinceClockIn quits.",
        ])
        #expect(banner.actions.map(\.title) == ["Try Again"])
    }

    @Test func closingDismissesNotificationsOffOnceItWasOnScreen() {
        var sighting = NotificationsBannerSighting()
        sighting.panelOpened()
        sighting.permissionRefreshed(showing: [.notificationsOff])
        sighting.panelShows([.stateSetAside(backup: backup), .saveFailed(reason: "The disk is full.")])

        let dismisses = sighting.panelClosed()

        #expect(dismisses)
    }

    @Test func closingWithoutSeeingNotificationsOffKeepsIt() {
        var sighting = NotificationsBannerSighting()
        sighting.panelOpened()
        sighting.permissionRefreshed(showing: [.stateSetAside(backup: backup), .saveFailed(reason: "The disk is full.")])

        let dismisses = sighting.panelClosed()

        #expect(!dismisses)
    }

    @Test func aBannerFromBeforeThisOpeningsPermissionReadDoesNotCount() {
        var sighting = NotificationsBannerSighting()
        sighting.panelOpened()
        sighting.panelShows([.notificationsOff])
        sighting.permissionRefreshed(showing: [])

        let dismisses = sighting.panelClosed()

        #expect(!dismisses)
    }

    @Test func aPermissionReadArrivingAfterClosingDoesNotCount() {
        var sighting = NotificationsBannerSighting()
        sighting.panelOpened()
        _ = sighting.panelClosed()
        sighting.permissionRefreshed(showing: [.notificationsOff])
        sighting.panelOpened()

        let dismisses = sighting.panelClosed()

        #expect(!dismisses)
    }

    @Test func eachOpeningStartsUnseen() {
        var sighting = NotificationsBannerSighting()
        sighting.panelOpened()
        sighting.permissionRefreshed(showing: [.notificationsOff])
        _ = sighting.panelClosed()
        sighting.panelOpened()

        let dismissesAgain = sighting.panelClosed()

        #expect(!dismissesAgain)
    }

    @Test func aDismissalLastsWhileNotificationsStayOff() {
        #expect(notificationsBannerStaysDismissed(true, notificationsAreOff: true))
    }

    @Test func turningNotificationsBackOnEndsTheDismissal() {
        #expect(!notificationsBannerStaysDismissed(true, notificationsAreOff: false))
        #expect(!notificationsBannerStaysDismissed(false, notificationsAreOff: true))
    }

    @Test func notificationsOffOffersSystemSettings() {
        let banner = Banner.notificationsOff

        #expect(banner.lines == ["Notifications are off, so only the menu bar shows that a login is about to expire."])
        #expect(banner.actions.map(\.title) == ["Open System Settings…"])
    }
}
