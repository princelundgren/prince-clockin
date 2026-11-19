import Observation
import PrinceClockInCore
import Sparkle

/// Sparkle's updater, with scheduled updates shown as a dot in the menu bar instead of a window
/// that would appear unasked behind other apps. "Check for Updates…" shows Sparkle's window. An
/// installed update's relaunch waits while a batch of logins runs.
@MainActor
@Observable
final class Updater: NSObject {
    /// The version of the update a scheduled check found, or of one installed whose relaunch
    /// waits, until its update session ends; `nil` when none waits.
    private(set) var updateVersion: String?
    /// Whether the user chose to install the update and its relaunch waits for the batch to end.
    var isRelaunchPostponed: Bool { postponedRelaunch != nil }

    @ObservationIgnored private let coordinator: Coordinator
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    /// Sparkle's go-ahead for a relaunch held back while a batch runs.
    private var postponedRelaunch: (() -> Void)?
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
            let mustWait = Observations { relaunchMustWait(batch: coordinator.batch) }
            for await waits in mustWait where !waits {
                guard !Task.isCancelled, let self else { return }
                let relaunch = postponedRelaunch
                endPostponement()
                relaunch?()
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
        guard relaunchMustWait(batch: coordinator.batch) else { return false }
        updateVersion = item.displayVersionString
        postponedRelaunch = installHandler
        relaunchWhenTheBatchEnds()
        return true
    }

    /// The update cycle that postponed a relaunch stays open until the relaunch goes ahead, so its
    /// end, after an aborted or cancelled install, means the postponement no longer holds.
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        guard isRelaunchPostponed else { return }
        endPostponement()
        updateVersion = nil
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
        if !state.userInitiated {
            updateVersion = update.displayVersionString
        }
    }

    /// Keeps the version while a relaunch waits, so the panel can say the update installs later.
    func standardUserDriverWillFinishUpdateSession() {
        if postponedRelaunch == nil { updateVersion = nil }
    }
}
