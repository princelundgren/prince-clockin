import Observation
import PrinceClockInCore
import Sparkle

/// Sparkle's updater, with scheduled updates shown as a dot in the menu bar instead of a window
/// that would appear unasked behind other apps. "Check for Updates…" shows Sparkle's window. An
/// installed update's relaunch waits while a batch of logins runs.
@MainActor
@Observable
final class Updater: NSObject {
    /// The waiting update and whether its relaunch is postponed; Sparkle's events drive it.
    private(set) var status = UpdateStatus()
    var updateVersion: String? { status.waitingVersion }
    var isRelaunchPostponed: Bool { status.isRelaunchPostponed }

    @ObservationIgnored private let coordinator: Coordinator
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    /// Sparkle's go-ahead for a relaunch held back while a batch runs.
    @ObservationIgnored private var postponedRelaunch: (() -> Void)?
    /// Waits for the batch to end, to give that go-ahead; at most one at a time.
    @ObservationIgnored private var batchWait: Task<Void, Never>?

    init(coordinator: Coordinator) {
        self.coordinator = coordinator
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    }

    /// Shows Sparkle's window: the update found, "no update", or the feed's error. For an update
    /// that waits, it brings that update's window forward.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Lets Sparkle relaunch, once, as soon as no batch runs, replacing any earlier wait.
    private func relaunchWhenTheBatchEnds() {
        batchWait?.cancel()
        batchWait = Task { [weak self, coordinator] in
            let isBatchRunning = Observations { coordinator.batch != nil }
            for await running in isBatchRunning where !running {
                guard !Task.isCancelled, let self else { return }
                let relaunch = postponedRelaunch
                endPostponement()
                if status.batchEnded() { relaunch?() }
                return
            }
        }
    }

    private func endPostponement() {
        batchWait?.cancel()
        batchWait = nil
        postponedRelaunch = nil
    }
}

extension Updater: SPUUpdaterDelegate {
    func updater(
        _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard status.relaunchRequested(version: item.displayVersionString, isBatchRunning: coordinator.batch != nil)
        else { return false }
        postponedRelaunch = installHandler
        relaunchWhenTheBatchEnds()
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        status.updateCycleFinished()
        endPostponement()
    }
}

extension Updater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        status.foundUpdate(version: update.displayVersionString, isUserInitiated: state.userInitiated)
    }

    func standardUserDriverWillFinishUpdateSession() {
        status.updateSessionFinished()
    }
}
