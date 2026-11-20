import PrinceClockInCore
import SwiftUI

/// Settings → Presets: the presets with + and − below them, then the selected preset's Name and
/// the logins it logs in to, in order.
struct PresetsSettings: View {
    let coordinator: Coordinator
    @State private var selection: UUID?

    private var presets: [Preset] { coordinator.model.state.presets }
    private var selected: Preset? { presets.first { $0.id == selection } }

    var body: some View {
        Form {
            Section("Presets") {
                List(selection: $selection) {
                    ForEach(presets) { preset in
                        Text(preset.name)
                            .lineLimit(1)
                            .tag(preset.id)
                    }
                }
                .frame(minHeight: 120)
                .accessibilityLabel("Presets")
                listButtons
            }
            if let selected {
                PresetForm(preset: selected, coordinator: coordinator)
                    .id(selected.id)
            }
        }
        .formStyle(.grouped)
    }

    private var listButtons: some View {
        HStack(spacing: 4) {
            Button("Add Preset", systemImage: "plus", action: add)
                .labelStyle(.iconOnly)
                .help("Add a preset.")
            Button("Remove Preset", systemImage: "minus", action: removeSelected)
                .labelStyle(.iconOnly)
                .disabled(selected == nil)
                .help(removePresetHelp(for: selected))
            Spacer()
        }
        .buttonStyle(.borderless)
    }

    /// Adds an empty preset and selects it, for its Name and logins to be filled in.
    private func add() {
        let preset = Preset(name: newPresetName(existingNames: presets.map(\.name)), loginIDs: [])
        coordinator.savePreset(preset)
        selection = preset.id
    }

    private func removeSelected() {
        guard let selected else { return }
        coordinator.removePreset(id: selected.id)
        selection = nil
    }
}

/// The selected preset's Name, and "Logs in to, in order": its logins with + (the tracked logins
/// not in it), −, Move Up and Move Down below them. Dragging a login also reorders them; Move Up
/// and Move Down are the keyboard's and VoiceOver's way.
private struct PresetForm: View {
    let preset: Preset
    let coordinator: Coordinator
    @State private var selection: UUID?

    private var logins: [Login] { coordinator.model.logins(in: preset) }
    private var members: PresetMembers { PresetMembers(logins.map(\.id)) }

    var body: some View {
        Section(preset.name) {
            CommitField("Name", text: preset.name) { name in
                guard !name.isEmpty else { return false }
                var renamed = preset
                renamed.name = name
                coordinator.savePreset(renamed)
                return true
            }
        }
        Section("Logs in to, in order") {
            List(selection: $selection) {
                ForEach(Array(logins.enumerated()), id: \.element.id) { index, login in
                    Text("\(index + 1). \(login.displayName)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .tag(login.id)
                }
                .onMove { offsets, destination in
                    edit { $0.move(fromOffsets: offsets, toOffset: destination) }
                }
            }
            .frame(minHeight: 120)
            .accessibilityLabel("Logs in to, in order")
            memberButtons
        }
    }

    private var memberButtons: some View {
        let loginsToAdd = members.loginsToAdd(from: coordinator.model.state.logins)
        return HStack(spacing: 4) {
            Menu {
                ForEach(loginsToAdd) { login in
                    Button(login.displayName) {
                        edit { $0.add(login.id) }
                        selection = login.id
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .accessibilityLabel("Add Login")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(loginsToAdd.isEmpty)
            .help("Add a login to this preset.")
            Button("Remove Login", systemImage: "minus") {
                guard let selection else { return }
                edit { $0.remove(selection) }
                self.selection = nil
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(selection == nil)
            .help("Remove the selected login from this preset.")
            Spacer()
            Button("Move Up") {
                guard let selection else { return }
                edit { $0.moveUp(selection) }
            }
            .controlSize(.small)
            .disabled(!members.canMoveUp(selection))
            Button("Move Down") {
                guard let selection else { return }
                edit { $0.moveDown(selection) }
            }
            .controlSize(.small)
            .disabled(!members.canMoveDown(selection))
        }
    }

    private func edit(_ change: (inout PresetMembers) -> Void) {
        var edited = members
        change(&edited)
        var saved = preset
        saved.loginIDs = edited.ids
        coordinator.savePreset(saved)
    }
}
