/// Whether an installed update's relaunch must wait: while a batch runs, since quitting would end
/// it. It goes ahead once the batch ends.
public func relaunchMustWait(batch: BatchProgress?) -> Bool {
    batch != nil
}

/// The panel's line about the waiting update `version`. `isRelaunchPostponed` is whether the user
/// chose to install it and its relaunch waits for the logins to finish.
public func updateLineText(version: String, isRelaunchPostponed: Bool) -> String {
    isRelaunchPostponed ? "Update \(version) installs after the logins finish" : "Update \(version) available"
}
