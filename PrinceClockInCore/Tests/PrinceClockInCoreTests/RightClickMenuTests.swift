import Testing
import PrinceClockInCore

@Suite struct RightClickMenuTests {
    @Test func withNothingWaitingTheMenuHasTheAppsCommands() {
        #expect(rightClickMenu(dueCount: 0, isBatchRunning: false, updateVersion: nil, isRelaunchPostponed: false) == [
            .settings, .separator, .checkForUpdates, .reportIssue, .separator, .quit,
        ])
    }

    @Test func logInToDueAndInstallUpdateComeFirst() {
        #expect(rightClickMenu(dueCount: 2, isBatchRunning: false, updateVersion: "1.0.1", isRelaunchPostponed: false) == [
            .logInToDue(count: 2), .installUpdate(version: "1.0.1"), .separator,
            .settings, .separator, .checkForUpdates, .reportIssue, .separator, .quit,
        ])
    }

    @Test func installUpdateHidesWhileItsRelaunchIsPostponed() {
        #expect(rightClickMenu(dueCount: 0, isBatchRunning: true, updateVersion: "1.0.1", isRelaunchPostponed: true) == [
            .settings, .separator, .checkForUpdates, .reportIssue, .separator, .quit,
        ])
    }

    @Test func logInToDueShowsOnlyWhenThePanelWouldShowIt() {
        #expect(showsLogInToDue(dueCount: 2, isBatchRunning: false))
        #expect(!showsLogInToDue(dueCount: 1, isBatchRunning: false))
        #expect(!showsLogInToDue(dueCount: 3, isBatchRunning: true))
        #expect(!rightClickMenu(dueCount: 1, isBatchRunning: false, updateVersion: nil, isRelaunchPostponed: false).contains(.logInToDue(count: 1)))
        #expect(!rightClickMenu(dueCount: 3, isBatchRunning: true, updateVersion: nil, isRelaunchPostponed: false).contains(.logInToDue(count: 3)))
    }

    @Test func itemsUseTheGlossarysTitlesAndShortcuts() {
        #expect(RightClickMenuItem.logInToDue(count: 2).title == "Log In to 2 Due")
        #expect(RightClickMenuItem.installUpdate(version: "1.0.1").title == "Install Update 1.0.1…")
        #expect(RightClickMenuItem.settings.title == "Settings…")
        #expect(RightClickMenuItem.settings.keyEquivalent == ",")
        #expect(RightClickMenuItem.checkForUpdates.title == "Check for Updates…")
        #expect(RightClickMenuItem.reportIssue.title == "Report an Issue…")
        #expect(RightClickMenuItem.quit.title == "Quit PrinceClockIn")
        #expect(RightClickMenuItem.quit.keyEquivalent == "q")
        #expect(RightClickMenuItem.reportIssue.keyEquivalent == "")
    }
}
