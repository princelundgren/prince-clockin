import Foundation
import Testing
import PrinceClockInCore

private let gb = Locale(identifier: "en_GB")

private func named(_ name: String) -> Login {
    Login(displayName: name, kind: .awsSSOSession(name: name))
}

@Suite struct PresetButtonTests {
    @Test func aPresetListsItsLoginsUnderItsNameAndInItsHelpTag() {
        let preset = Preset(name: "Morning", loginIDs: [])

        let tile = presetButton(for: preset, logins: [named("dev"), named("prod"), named("staging")], locale: gb)

        #expect(tile == PresetButton(
            id: preset.id, title: "Morning", subtitle: "dev, prod, staging",
            helpTag: "Logs in to dev, prod and staging",
            accessibilityLabel: "Morning preset", isEnabled: true))
    }

    @Test func aPresetOfOneLoginNamesIt() {
        let preset = Preset(name: "Prod only", loginIDs: [])

        let tile = presetButton(for: preset, logins: [named("prod")], locale: gb)

        #expect(tile.subtitle == "prod")
        #expect(tile.helpTag == "Logs in to prod")
    }

    @Test func anEmptyPresetIsDisabledSaysNoLoginsAndPointsToSettings() {
        let preset = Preset(name: "Night shift", loginIDs: [])

        let tile = presetButton(for: preset, logins: [], locale: gb)

        #expect(tile == PresetButton(
            id: preset.id, title: "Night shift", subtitle: "No logins",
            helpTag: "Add logins to it in Settings → Presets.",
            accessibilityLabel: "Night shift preset, no logins", isEnabled: false))
    }
}
