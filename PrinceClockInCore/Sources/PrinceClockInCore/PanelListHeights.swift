/// How tall the panel draws its login list and its preset list; past these heights each scrolls.
public struct PanelListHeights: Equatable, Sendable {
    public let logins: Double
    public let presets: Double

    public init(logins: Double, presets: Double) {
        self.logins = logins
        self.presets = presets
    }
}

/// The heights of the panel's two lists, given each tile's height in order, the gap between tiles
/// and the `room` the screen leaves both lists, or `nil` when it isn't known.
///
/// The logins show up to eight tiles and the presets up to five, a half tile more when more follow,
/// so the cut one shows the list scrolls. When the room is short, the presets keep up to three
/// tiles, and half of a fourth when more follow, and the logins give up height first; room left
/// after the logins goes to the presets.
public func panelListHeights(
    loginTiles: [Double], presetTiles: [Double], spacing: Double, room: Double?
) -> PanelListHeights {
    let logins = visibleHeight(of: loginTiles, upTo: 8, spacing: spacing)
    let presets = visibleHeight(of: presetTiles, upTo: 5, spacing: spacing)
    guard let room = room.map({ max(0, $0) }) else { return PanelListHeights(logins: logins, presets: presets) }
    let presetsFloor = min(visibleHeight(of: presetTiles, upTo: 3, spacing: spacing), room)
    let loginsShare = min(logins, max(0, room - presetsFloor))
    return PanelListHeights(logins: loginsShare, presets: min(presets, max(presetsFloor, room - loginsShare)))
}

/// The height of the first `count` tiles and the gaps between them, and half of the next tile with
/// its gap when there is one.
private func visibleHeight(of tiles: [Double], upTo count: Int, spacing: Double) -> Double {
    let shown = tiles.prefix(count)
    let whole = shown.reduce(0, +) + spacing * Double(max(shown.count - 1, 0))
    guard tiles.count > count else { return whole }
    return whole + spacing + tiles[count] / 2
}
