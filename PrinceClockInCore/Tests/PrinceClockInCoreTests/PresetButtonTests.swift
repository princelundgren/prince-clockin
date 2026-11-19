import Foundation
import Testing
import PrinceClockInCore

private let gb = Locale(identifier: "en_GB")

private func named(_ name: String) -> Login {
    Login(displayName: name, kind: .awsSSOSession(name: name))
}

@Suite struct PresetButtonTests {
    @Test func aPresetIsNamedAndListsItsLoginsInItsHelpTag() {
        let preset = Preset(name: "Morning", loginIDs: [])

        let button = presetButton(for: preset, logins: [named("dev"), named("prod"), named("staging")], locale: gb)

        #expect(button == PresetButton(
            id: preset.id, title: "Morning", note: nil, helpTag: "Logs in to dev, prod and staging",
            isEnabled: true))
    }

    @Test func aPresetOfOneLoginNamesIt() {
        let preset = Preset(name: "Prod only", loginIDs: [])

        let button = presetButton(for: preset, logins: [named("prod")], locale: gb)

        #expect(button.helpTag == "Logs in to prod")
    }

    @Test func anEmptyPresetIsDisabledAndPointsToSettings() {
        let preset = Preset(name: "Night shift", loginIDs: [])

        let button = presetButton(for: preset, logins: [], locale: gb)

        #expect(button == PresetButton(
            id: preset.id, title: "Night shift", note: "No logins", helpTag: "Add logins to it in Settings → Presets.",
            isEnabled: false))
    }

    @Test func aLongEmptyPresetKeepsItsNoteOutsideTheNameThatTruncates() {
        let preset = Preset(name: "Quarterly data platform reconciliation", loginIDs: [])

        let button = presetButton(for: preset, logins: [], locale: gb)

        #expect(button.title == "Quarterly data platform reconciliation")
        #expect(button.note == "No logins")
    }
}
