import PrinceClockInCore
import SwiftUI

/// Settings → Presets: the presets, which a drag reorders, with + and − below them, then the
/// selected preset's Name and the logins it logs in to, in order. The first preset is selected
/// when the pane opens.
struct PresetsSettings: View {
    let coordinator: Coordinator
    @State private var selection: UUID?
    /// The preset + just added, whose Name takes focus until another preset is selected.
    @State private var newPresetID: UUID?

    private var presets: [Preset] { coordinator.model.state.presets }
    private var selected: Preset? { presets.first { $0.id == selection } }

    var body: some View {
        Form {
            Section("Presets") {
                List(selection: $selection) {
                    ForEach(presets) { preset in
                        PresetRow(preset: preset, logins: coordinator.model.logins(in: preset))
                            .tag(preset.id)
                    }
                    .onMove { offsets, destination in
                        var order = ListOrder(presets.map(\.id))
                        order.move(fromOffsets: offsets, toOffset: destination)
                        coordinator.setPresetOrder(order.ids)
                    }
                }
                .frame(minHeight: 160)
                .overlay {
                    if presets.isEmpty {
                        ContentUnavailableView(
                            "No Presets", systemImage: "rectangle.stack",
                            description: Text("A preset logs in to several logins with one click. Click + to make one."))
                    }
                }
                .accessibilityLabel("Presets")
                listButtons
            }
            if let selected {
                PresetForm(preset: selected, coordinator: coordinator, focusesName: selected.id == newPresetID)
                    .id(selected.id)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if selection == nil { selection = presets.first?.id }
        }
        .onChange(of: selection) { _, new in
            if new != newPresetID { newPresetID = nil }
        }
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

    /// Adds an empty preset and selects it, with its Name focused for it to be named.
    private func add() {
        let preset = Preset(name: newPresetName(existingNames: presets.map(\.name)), loginIDs: [])
        coordinator.savePreset(preset)
        newPresetID = preset.id
        selection = preset.id
    }

    /// Removes the selected preset at once and selects the one that takes its place.
    private func removeSelected() {
        guard let selected else { return }
        let next = selectionAfterRemoving(selected.id, from: presets.map(\.id))
        coordinator.removePreset(id: selected.id)
        selection = next
    }
}

/// A preset in the list: the preset symbol, its name and the logins it logs in to.
private struct PresetRow: View {
    let preset: Preset
    let logins: [Login]

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.stack")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(presetTile(for: preset, logins: logins, locale: .current).subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// The selected preset's form, headed by the preset symbol, its name and how many logins it has:
/// Name, and "Logs in to, in order": its logins, which a drag reorders, with + (the tracked logins
/// not in it) and − below them.
private struct PresetForm: View {
    let preset: Preset
    let coordinator: Coordinator
    let focusesName: Bool
    @State private var selection: UUID?

    private var logins: [Login] { coordinator.model.logins(in: preset) }
    private var members: ListOrder { ListOrder(logins.map(\.id)) }

    var body: some View {
        Section {
            CommitField("Name", text: preset.name, focusesOnAppear: focusesName) { name in
                guard !name.isEmpty else { return false }
                coordinator.renamePreset(id: preset.id, to: name)
                return true
            }
            .textFieldStyle(.roundedBorder)
        } header: {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.stack")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(presetLoginCount(logins.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
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
        }
    }

    private func edit(_ change: (inout ListOrder) -> Void) {
        var edited = members
        change(&edited)
        var saved = preset
        saved.loginIDs = edited.ids
        coordinator.savePreset(saved)
    }
}
