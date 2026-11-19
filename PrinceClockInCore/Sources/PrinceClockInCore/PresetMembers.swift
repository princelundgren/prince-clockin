import Foundation

/// A preset's logins, in order, as Settings → Presets edits them. Each edit keeps the order of the
/// rest; `ids` is what the preset stores afterwards.
public struct PresetMembers: Equatable, Sendable {
    public private(set) var ids: [UUID]

    /// `ids` are the preset's tracked logins in its order (`LoginsModel.logins(in:)`).
    public init(_ ids: [UUID]) {
        self.ids = ids
    }

    /// The + menu: the tracked `logins` not in the preset, in their stored order.
    public func loginsToAdd(from logins: [Login]) -> [Login] {
        logins.filter { !ids.contains($0.id) }
    }

    /// Adds login `id` last, unless it is already in the preset.
    public mutating func add(_ id: UUID) {
        guard !ids.contains(id) else { return }
        ids.append(id)
    }

    public mutating func remove(_ id: UUID) {
        ids.removeAll { $0 == id }
    }

    /// Whether Move Up is available for the selected login `id`: not for the first, nor with
    /// nothing selected.
    public func canMoveUp(_ id: UUID?) -> Bool {
        guard let id, let index = ids.firstIndex(of: id) else { return false }
        return index > ids.startIndex
    }

    /// Whether Move Down is available for the selected login `id`: not for the last, nor with
    /// nothing selected.
    public func canMoveDown(_ id: UUID?) -> Bool {
        guard let id, let index = ids.firstIndex(of: id) else { return false }
        return index < ids.endIndex - 1
    }

    /// Swaps login `id` with the one before it; the first stays where it is.
    public mutating func moveUp(_ id: UUID) {
        guard canMoveUp(id), let index = ids.firstIndex(of: id) else { return }
        ids.swapAt(index, index - 1)
    }

    /// Swaps login `id` with the one after it; the last stays where it is.
    public mutating func moveDown(_ id: UUID) {
        guard canMoveDown(id), let index = ids.firstIndex(of: id) else { return }
        ids.swapAt(index, index + 1)
    }

    /// A drag: moves the logins at `offsets` to before the one at `destination`, an offset in the
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
