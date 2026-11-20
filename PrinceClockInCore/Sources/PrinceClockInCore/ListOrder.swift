import Foundation

/// A list Settings orders: the tracked logins, the presets, or a preset's logins. Each edit keeps
/// the order of the rest; `ids` is the order stored afterwards. `add`, `remove` and
/// `loginsToAdd(from:)` serve a preset's logins; the other lists only `move`.
public struct ListOrder: Equatable, Sendable {
    public private(set) var ids: [UUID]

    /// `ids` are the list's items in their current order.
    public init(_ ids: [UUID]) {
        self.ids = ids
    }

    /// A preset's + menu: the tracked `logins` not in the list, in their stored order.
    public func loginsToAdd(from logins: [Login]) -> [Login] {
        logins.filter { !ids.contains($0.id) }
    }

    /// Adds `id` last, unless it is already in the list.
    public mutating func add(_ id: UUID) {
        guard !ids.contains(id) else { return }
        ids.append(id)
    }

    public mutating func remove(_ id: UUID) {
        ids.removeAll { $0 == id }
    }

    /// A drag: moves the items at `offsets` to before the one at `destination`, an offset in the
    /// order before the move (`ids.count` puts them last), keeping their order, as a list's
    /// `onMove` reports it.
    public mutating func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let moved = offsets.map { ids[$0] }
        let insertion = destination - offsets.count(in: 0..<destination)
        var rest = ids.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        rest.insert(contentsOf: moved, at: insertion)
        ids = rest
    }
}
