import Foundation
import Testing
import PrinceClockInCore

@Suite struct SettingsTextTests {
    // MARK: Presets

    @Test func aNewPresetIsNamedNewPresetWhenThatNameIsFree() {
        #expect(newPresetName(existingNames: ["Morning"]) == "New preset")
    }

    @Test func aNewPresetTakesTheFirstFreeNumber() {
        #expect(newPresetName(existingNames: ["New preset"]) == "New preset 2")
        #expect(newPresetName(existingNames: ["New preset", "New preset 2", "New preset 4"]) == "New preset 3")
    }

    @Test func minusHelpTagNamesTheSelectedPreset() {
        #expect(removePresetHelp(for: Preset(name: "Morning", loginIDs: [])) == "Remove Morning.")
        #expect(removePresetHelp(for: nil) == "Remove the selected preset.")
    }
}
