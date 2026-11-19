import Observation
import Sparkle

/// Sparkle's updater, with scheduled updates shown as a dot in the menu bar instead of a window
/// that would appear unasked behind other apps. "Check for Updates…" shows Sparkle's window.
@MainActor
@Observable
final class Updater: NSObject {
    /// The version of the update a scheduled check found, until its update session ends; `nil`
    /// when none waits.
    private(set) var updateVersion: String?

    @ObservationIgnored private var controller: SPUStandardUpdaterController?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    /// Shows Sparkle's window: the update found, "no update", or the feed's error. For an update
    /// that waits, it brings that update's window forward.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
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

    func standardUserDriverWillFinishUpdateSession() {
        updateVersion = nil
    }
}
