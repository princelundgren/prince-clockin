import Foundation

/// A key whose meaning in the panel depends on its state and focus. Escape has its own rule,
/// `escapeResponse(openSetTimer:tiles:)`; Space, Tab and the keys a focused control handles itself
/// stay with the system.
public enum PanelKey: Sendable {
    case returnKey
    case moveUp
    case moveDown
}

/// What a `PanelKey` does.
public enum PanelKeyResponse: Equatable, Sendable {
    case perform(ProminentAction)
    case focusTile(UUID)
    /// The key is left to whatever has focus: a text field commits on Return.
    case passThrough
}

/// What the panel's keys depend on.
public struct PanelKeyContext: Sendable {
    public var prominent: ProminentAction?
    /// The login whose Set Timer is open.
    public var openSetTimer: UUID?
    /// Whether a text field has focus.
    public var isEditingText: Bool
    /// The tiles, in panel order.
    public var tiles: [UUID]
    public var focusedTile: UUID?

    public init(
        prominent: ProminentAction?, openSetTimer: UUID?, isEditingText: Bool, tiles: [UUID], focusedTile: UUID?
    ) {
        self.prominent = prominent
        self.openSetTimer = openSetTimer
        self.isEditingText = isEditingText
        self.tiles = tiles
        self.focusedTile = focusedTile
    }

    /// The keys' context for login `id`'s Set Timer shown on its own, outside the panel, such as
    /// Settings' prompt after adding a login: Set is the default and Escape cancels the form.
    public static func setTimerAlone(id: UUID, isEditingText: Bool) -> PanelKeyContext {
        PanelKeyContext(
            prominent: .set(id: id), openSetTimer: id, isEditingText: isEditingText, tiles: [id], focusedTile: nil)
    }
}

/// What `key` does in `context`: Return triggers the prominent action wherever focus is, except in
/// a text field; the up and down arrows move focus to the tile before or after the focused one,
/// stopping at the ends.
public func panelKeyResponse(to key: PanelKey, in context: PanelKeyContext) -> PanelKeyResponse {
    switch key {
    case .returnKey:
        guard !context.isEditingText, let prominent = context.prominent else { return .passThrough }
        return .perform(prominent)
    case .moveUp, .moveDown:
        guard let focused = context.focusedTile, let index = context.tiles.firstIndex(of: focused) else {
            return .passThrough
        }
        let next = key == .moveUp ? index - 1 : index + 1
        return context.tiles.indices.contains(next) ? .focusTile(context.tiles[next]) : .passThrough
    }
}

/// What Escape does in the panel.
public enum EscapeResponse: Equatable, Sendable {
    case cancelSetTimer(id: UUID)
    case closePanel
}

/// What Escape does, wherever focus is: cancels the open Set Timer while its login is among
/// `tiles`, else closes the panel.
public func escapeResponse(openSetTimer: UUID?, tiles: [UUID]) -> EscapeResponse {
    guard let id = openSetTimer, tiles.contains(id) else { return .closePanel }
    return .cancelSetTimer(id: id)
}
