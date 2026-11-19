import Foundation

/// A preset's button in the panel.
public struct PresetButton: Equatable, Identifiable, Sendable {
    public let id: UUID
    /// The preset's name, which the view truncates at the end.
    public let title: String
    /// What the view shows after the name, joined by " · " and never truncated ("No logins").
    public let note: String?
    public let helpTag: String
    public let isEnabled: Bool

    public init(id: UUID, title: String, note: String?, helpTag: String, isEnabled: Bool) {
        self.id = id
        self.title = title
        self.note = note
        self.helpTag = helpTag
        self.isEnabled = isEnabled
    }
}

/// The button for `preset`, whose tracked `logins` are given in its order: its help tag lists them,
/// joined as `locale` joins a list. An empty preset is disabled and its help tag says where to add
/// logins.
public func presetButton(for preset: Preset, logins: [Login], locale: Locale) -> PresetButton {
    guard !logins.isEmpty else {
        return PresetButton(
            id: preset.id, title: preset.name, note: "No logins", helpTag: "Add logins to it in Settings → Presets.",
            isEnabled: false)
    }
    let names = logins.map(\.displayName).formatted(.list(type: .and).locale(locale))
    return PresetButton(
        id: preset.id, title: preset.name, note: nil, helpTag: "Logs in to \(names)", isEnabled: true)
}
