import Testing
import PrinceClockInCore

@Suite struct UpdatesTests {
    @Test func noUpdateWaitsAtFirst() {
        let status = UpdateStatus()

        #expect(status.waitingVersion == nil)
        #expect(!status.isRelaunchPostponed)
        #expect(status.line == nil)
    }

    @Test func aScheduledCheckLeavesTheUpdateWaitingWithView() {
        var status = UpdateStatus()

        status.foundUpdate(version: "1.0.1", isUserInitiated: false)

        #expect(status.waitingVersion == "1.0.1")
        #expect(status.line == UpdateLine(text: "Update 1.0.1 available", showsView: true))
    }

    @Test func aCheckTheUserStartedShowsSparklesWindowInstead() {
        var status = UpdateStatus()

        status.foundUpdate(version: "1.0.1", isUserInitiated: true)

        #expect(status.waitingVersion == nil)
    }

    @Test func theRelaunchIsPostponedWhileABatchRuns() {
        var status = UpdateStatus()

        let postpones = status.relaunchRequested(version: "1.0.1", isBatchRunning: true)

        #expect(postpones)
        #expect(status.isRelaunchPostponed)
        #expect(status.line == UpdateLine(text: "Update 1.0.1 installs after the logins finish", showsView: false))
    }

    @Test func theRelaunchGoesAheadWithNoBatchRunning() {
        var status = UpdateStatus()
        status.foundUpdate(version: "1.0.1", isUserInitiated: false)

        let postpones = status.relaunchRequested(version: "1.0.1", isBatchRunning: false)

        #expect(!postpones)
        #expect(!status.isRelaunchPostponed)
    }

    @Test func thePostponedRelaunchGoesAheadOnceTheBatchEnds() {
        var status = UpdateStatus()
        _ = status.relaunchRequested(version: "1.0.1", isBatchRunning: true)

        let relaunches = status.batchEnded()
        let relaunchesAgain = status.batchEnded()

        #expect(relaunches)
        #expect(!relaunchesAgain)
        #expect(!status.isRelaunchPostponed)
    }

    @Test func aBatchEndingWithNothingPostponedRelaunchesNothing() {
        var status = UpdateStatus()
        status.foundUpdate(version: "1.0.1", isUserInitiated: false)

        let relaunches = status.batchEnded()

        #expect(!relaunches)
        #expect(status.waitingVersion == "1.0.1")
    }

    @Test func aPostponedUpdateSurvivesTheEndOfSparklesSession() {
        var status = UpdateStatus()
        _ = status.relaunchRequested(version: "1.0.1", isBatchRunning: true)

        status.updateSessionFinished()

        #expect(status.waitingVersion == "1.0.1")
        #expect(status.isRelaunchPostponed)
    }

    @Test func theEndOfSparklesSessionOtherwiseClearsTheUpdate() {
        var status = UpdateStatus()
        status.foundUpdate(version: "1.0.1", isUserInitiated: false)

        status.updateSessionFinished()

        #expect(status.line == nil)
    }

    @Test func anAbortedInstallEndsThePostponementAndTheUpdate() {
        var status = UpdateStatus()
        _ = status.relaunchRequested(version: "1.0.1", isBatchRunning: true)

        status.updateCycleFinished()
        let relaunches = status.batchEnded()

        #expect(!status.isRelaunchPostponed)
        #expect(status.waitingVersion == nil)
        #expect(!relaunches)
    }

    @Test func aCycleEndingWithNothingPostponedKeepsAFoundUpdate() {
        var status = UpdateStatus()
        status.foundUpdate(version: "1.0.1", isUserInitiated: false)

        status.updateCycleFinished()

        #expect(status.waitingVersion == "1.0.1")
    }
}
