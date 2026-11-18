import Observation
import Sparkle

/// Sparkle's updater, with scheduled updates shown as a dot in the menu bar instead of a window
/// that would appear unasked behind other apps. "Check for Updates…" shows Sparkle's window.
@MainActor
@Observable
final class Updater: NSObject {
    /// Whether a scheduled check found an update the user hasn't looked at yet.
    private(set) var updateAvailable = false

    @ObservationIgnored private var controller: SPUStandardUpdaterController?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    /// Shows Sparkle's window: the update found, "no update", or the feed's error.
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
            updateAvailable = true
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        updateAvailable = false
    }

    func standardUserDriverWillFinishUpdateSession() {
        updateAvailable = false
    }
}
