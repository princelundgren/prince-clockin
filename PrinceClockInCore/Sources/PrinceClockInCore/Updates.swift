/// The update a scheduled check found, and whether its relaunch is postponed until the running
/// batch of logins ends, since quitting would end the batch. The app feeds it Sparkle's events and
/// acts on its answers.
public struct UpdateStatus: Equatable, Sendable {
    /// The version of the update that waits: found by a scheduled check, or installed with its
    /// relaunch postponed. `nil` when none waits.
    public private(set) var waitingVersion: String?
    /// Whether the update is installed and its relaunch waits for the batch to end.
    public private(set) var isRelaunchPostponed = false

    public init() {}

    /// The panel's update line, or `nil` when no update waits.
    public var line: UpdateLine? {
        guard let waitingVersion else { return nil }
        return isRelaunchPostponed
            ? UpdateLine(text: "Update \(waitingVersion) installs after the logins finish", showsView: false)
            : UpdateLine(text: "Update \(waitingVersion) available", showsView: true)
    }

    /// A check found update `version`. One the user started shows Sparkle's window, so only a
    /// scheduled check's update waits.
    public mutating func foundUpdate(version: String, isUserInitiated: Bool) {
        if !isUserInitiated { waitingVersion = version }
    }

    /// Sparkle is ready to relaunch into the installed `version`. Returns whether to postpone the
    /// relaunch: while a batch runs.
    public mutating func relaunchRequested(version: String, isBatchRunning: Bool) -> Bool {
        guard isBatchRunning else { return false }
        waitingVersion = version
        isRelaunchPostponed = true
        return true
    }

    /// The batch ended. Returns whether a postponed relaunch goes ahead now, which it does once.
    public mutating func batchEnded() -> Bool {
        defer { isRelaunchPostponed = false }
        return isRelaunchPostponed
    }

    /// Sparkle's update cycle ended. A cycle that postponed a relaunch stays open until the
    /// relaunch goes ahead, so its end means the install was aborted or cancelled, and the update
    /// no longer waits.
    public mutating func updateCycleFinished() {
        guard isRelaunchPostponed else { return }
        isRelaunchPostponed = false
        waitingVersion = nil
    }

    /// Sparkle's update session ended: the update no longer waits, unless its relaunch is postponed.
    public mutating func updateSessionFinished() {
        if !isRelaunchPostponed { waitingVersion = nil }
    }
}

/// The panel's line about the waiting update.
public struct UpdateLine: Equatable, Sendable {
    public let text: String
    /// Whether the line offers View…, which shows Sparkle's update window.
    public let showsView: Bool

    public init(text: String, showsView: Bool) {
        self.text = text
        self.showsView = showsView
    }
}
