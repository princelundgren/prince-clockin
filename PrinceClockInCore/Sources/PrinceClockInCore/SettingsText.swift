import Foundation

/// The name + gives a new preset in Settings → Presets: "New preset", or the first of "New preset 2",
/// "New preset 3", … that no preset in `existingNames` has.
public func newPresetName(existingNames: [String]) -> String {
    let taken = Set(existingNames)
    let base = "New preset"
    var number = 1
    var name = base
    while taken.contains(name) {
        number += 1
        name = "\(base) \(number)"
    }
    return name
}

/// −'s help tag in Settings → Presets: the preset it removes.
public func removePresetHelp(for preset: Preset?) -> String {
    guard let preset else { return "Remove the selected preset." }
    return "Remove \(preset.name)."
}
