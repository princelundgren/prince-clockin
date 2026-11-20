import Foundation

/// A preset's tile in the panel.
public struct PresetButton: Equatable, Identifiable, Sendable {
    public let id: UUID
    /// The preset's name, which the view truncates at the end.
    public let title: String
    /// The line under the name: the preset's logins in order, or "No logins". The view keeps it to
    /// one line, truncated at the end.
    public let subtitle: String
    public let helpTag: String
    /// What VoiceOver reads for the whole tile; the help tag is its hint.
    public let accessibilityLabel: String
    public let isEnabled: Bool

    public init(
        id: UUID, title: String, subtitle: String, helpTag: String, accessibilityLabel: String, isEnabled: Bool
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.helpTag = helpTag
        self.accessibilityLabel = accessibilityLabel
        self.isEnabled = isEnabled
    }
}

/// The tile for `preset`, whose tracked `logins` are given in its order: its subtitle lists them as
/// `locale` writes a short list, and its help tag as it writes a sentence. An empty preset is
/// disabled and its help tag says where to add logins.
public func presetButton(for preset: Preset, logins: [Login], locale: Locale) -> PresetButton {
    guard !logins.isEmpty else {
        return PresetButton(
            id: preset.id, title: preset.name, subtitle: "No logins",
            helpTag: "Add logins to it in Settings → Presets.",
            accessibilityLabel: "\(preset.name) preset, no logins", isEnabled: false)
    }
    let names = logins.map(\.displayName)
    let shortList = names.formatted(.list(type: .and, width: .narrow).locale(locale))
    let sentenceList = names.formatted(.list(type: .and).locale(locale))
    return PresetButton(
        id: preset.id, title: preset.name, subtitle: shortList, helpTag: "Logs in to \(sentenceList)",
        accessibilityLabel: "\(preset.name) preset", isEnabled: true)
}
