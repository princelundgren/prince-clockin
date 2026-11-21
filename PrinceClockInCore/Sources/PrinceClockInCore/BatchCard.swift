import Foundation

/// The panel's card for the running batch.
public enum BatchCard: Equatable, Sendable {
    /// "Logging in to prod", its progress "1 of 2", what to do now and which login is next, and
    /// "1 failed" under the progress once a login of the batch failed.
    case running(title: String, progress: String, instruction: String?, failures: String?)
    /// Custom login `id` waits for the user's Done.
    case waitingForDone(id: UUID, title: String, instruction: String)
}

/// The card for `batch`, with the login `running` now, the `next` one queued, and how the batch's
/// finished logins ended. A custom login `waitingForDone` takes the card over until its Done. A
/// login run in the browser says to finish there; between two logins the card names neither.
public func batchCard(
    batch: BatchProgress, running: Login?, next: Login?, outcomes: [LoginOutcome], waitingForDone: Login?
) -> BatchCard {
    if let waitingForDone {
        let instruction = if case .custom(command: nil) = waitingForDone.kind {
            "Log in your own way, then click Done."
        } else {
            "Finish the login in Terminal, then click Done."
        }
        return .waitingForDone(
            id: waitingForDone.id, title: "\(waitingForDone.displayName) is waiting for you", instruction: instruction)
    }
    let runsInBrowser = switch running?.kind {
    case .awsSSOSession, .databricksProfile, .gcloudAccount, .azureTenant, .ociSessionProfile: true
    case .custom, nil: false
    }
    let parts = [runsInBrowser ? "Finish in your browser." : nil, next.map { "Next: \($0.displayName)" }]
    let instruction = parts.compactMap { $0 }.joined(separator: " ")
    let failedCount = outcomes.count { if case .failed = $0 { true } else { false } }
    return .running(
        title: running.map { "Logging in to \($0.displayName)" } ?? "Logging in",
        progress: batchProgressText(batch),
        instruction: instruction.isEmpty ? nil : instruction,
        failures: failedCount > 0 ? "\(failedCount) failed" : nil)
}
