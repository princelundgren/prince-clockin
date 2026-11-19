/// One item of the status item's right-click menu.
public enum RightClickMenuItem: Equatable, Sendable {
    case logInToDue(count: Int)
    case installUpdate(version: String)
    case settings
    case checkForUpdates
    case reportIssue
    case quit
    case separator

    /// The item's title, in the glossary's title case; empty for a separator.
    public var title: String {
        switch self {
        case .logInToDue(let count): "Log In to \(count) Due"
        case .installUpdate(let version): "Install Update \(version)…"
        case .settings: "Settings…"
        case .checkForUpdates: "Check for Updates…"
        case .reportIssue: "Report an Issue…"
        case .quit: "Quit PrinceClockIn"
        case .separator: ""
        }
    }

    /// The key that triggers the item with ⌘, or an empty string for none.
    public var keyEquivalent: String {
        switch self {
        case .settings: ","
        case .quit: "q"
        case .logInToDue, .installUpdate, .checkForUpdates, .reportIssue, .separator: ""
        }
    }
}

/// Whether Log In to N Due is offered, in the panel and the right-click menu: with two or more
/// due, since one due login's own Log In is the action then, and no batch running.
public func showsLogInToDue(dueCount: Int, isBatchRunning: Bool) -> Bool {
    dueCount >= 2 && !isBatchRunning
}

/// The right-click menu's items, in order. `updateVersion` is the waiting update's, or `nil`;
/// Install Update is left out once the user chose to install it and its relaunch is postponed.
public func rightClickMenu(
    dueCount: Int, isBatchRunning: Bool, updateVersion: String?, isRelaunchPostponed: Bool
) -> [RightClickMenuItem] {
    var actions: [RightClickMenuItem] = []
    if showsLogInToDue(dueCount: dueCount, isBatchRunning: isBatchRunning) { actions.append(.logInToDue(count: dueCount)) }
    if let updateVersion, !isRelaunchPostponed { actions.append(.installUpdate(version: updateVersion)) }
    if !actions.isEmpty { actions.append(.separator) }
    return actions + [.settings, .separator, .checkForUpdates, .reportIssue, .separator, .quit]
}
