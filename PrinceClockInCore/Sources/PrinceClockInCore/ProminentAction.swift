import Foundation

/// The panel's one prominent button: the state's single default.
public enum ProminentAction: Equatable, Sendable {
    /// Set, in the open Set Timer on this login's tile.
    case set(id: UUID)
    /// Done, for the custom login waiting for it.
    case done(id: UUID)
    case logInToDue
    /// A due tile's own Log In.
    case logIn(id: UUID)
    /// A due tile's Try Again, after its login failed.
    case tryAgain(id: UUID)
    /// A question's Mark as Logged In at <time>.
    case markAsLoggedInAt(id: UUID)
    /// Add Logins…, in the empty panel.
    case addLogins
}

/// The prominent button for the panel's `tiles`, in panel order, in the design's order: Set in the
/// Set Timer open on login `openSetTimer`, while its tile is shown; Done for custom login
/// `waitingForDone`; Log In to N Due; the first due tile with an action of its own (a Log In its
/// click runs, or Try Again when it failed); then the first question's Mark as Logged In at
/// <time>; with no tiles and no batch, Add Logins…. `nil` when nothing needs the user. Try Again is
/// never prominent during a batch; Cancel All and Run It never are.
public func prominentAction(
    openSetTimer: UUID?, waitingForDone: UUID?, tiles: [TilePresentation], showsLogInToDue: Bool,
    isBatchRunning: Bool
) -> ProminentAction? {
    if let openSetTimer, tiles.contains(where: { $0.id == openSetTimer }) { return .set(id: openSetTimer) }
    if let waitingForDone { return .done(id: waitingForDone) }
    if showsLogInToDue { return .logInToDue }
    for tile in tiles where tile.isDue {
        if tile.clickLogsIn { return .logIn(id: tile.id) }
        if case .failed = tile.detail, !isBatchRunning { return .tryAgain(id: tile.id) }
    }
    for tile in tiles {
        if case .possibleLogin = tile.detail { return .markAsLoggedInAt(id: tile.id) }
    }
    if tiles.isEmpty, !isBatchRunning { return .addLogins }
    return nil
}
