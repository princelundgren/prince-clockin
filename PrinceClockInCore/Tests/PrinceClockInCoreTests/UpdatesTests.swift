import Testing
import PrinceClockInCore

@Suite struct UpdatesTests {
    @Test func relaunchWaitsWhileABatchRuns() {
        #expect(relaunchMustWait(batch: BatchProgress(position: 1, total: 2)))
        #expect(!relaunchMustWait(batch: nil))
    }

    @Test func updateLineSaysWhenTheUpdateInstalls() {
        #expect(updateLineText(version: "1.0.1", isRelaunchPostponed: false) == "Update 1.0.1 available")
        #expect(updateLineText(version: "1.0.1", isRelaunchPostponed: true) == "Update 1.0.1 installs after the logins finish")
    }
}
