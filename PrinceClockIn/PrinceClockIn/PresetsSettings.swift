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
/// Name, and "Logs in to, in order": its logins, which a drag reorders, each with a remove button,
/// then the tracked logins not in it, each with an add button. With no logins tracked, it offers
/// Settings → Logins instead.
private struct PresetForm: View {
    let preset: Preset
    let coordinator: Coordinator
    let focusesName: Bool
    @AppStorage(SettingsView.paneKey) private var pane: SettingsPane = .logins

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
            if coordinator.model.state.logins.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SettingsNote("No logins are tracked yet.")
                    Button("Show Logins") { pane = .logins }
                        .controlSize(.small)
                }
            } else {
                loginsList
                SettingsNote("Logs in one at a time, top to bottom. Drag to change the order.")
            }
        }
    }

    /// The preset's logins, numbered, then every other tracked login under "Not in this preset".
    private var loginsList: some View {
        let loginsToAdd = members.loginsToAdd(from: coordinator.model.state.logins)
        return List {
            Section {
                ForEach(Array(logins.enumerated()), id: \.element.id) { index, login in
                    PresetLoginRow(
                        login: login, number: index + 1,
                        action: removeFromPresetAction(for: login, preset: preset), systemImage: "minus.circle"
                    ) {
                        edit { $0.remove(login.id) }
                    }
                }
                .onMove { offsets, destination in
                    edit { $0.move(fromOffsets: offsets, toOffset: destination) }
                }
                if logins.isEmpty {
                    Text("No logins yet. Add them from the list below.")
                        .foregroundStyle(.secondary)
                }
            }
            if !loginsToAdd.isEmpty {
                Section("Not in this preset") {
                    ForEach(loginsToAdd) { login in
                        PresetLoginRow(
                            login: login, number: nil,
                            action: addToPresetAction(for: login, preset: preset), systemImage: "plus.circle"
                        ) {
                            edit { $0.add(login.id) }
                        }
                    }
                }
            }
        }
        .frame(minHeight: 200)
        .accessibilityLabel("Logs in to, in order")
    }

    private func edit(_ change: (inout ListOrder) -> Void) {
        var edited = members
        change(&edited)
        var saved = preset
        saved.loginIDs = edited.ids
        coordinator.savePreset(saved)
    }
}

/// A login in "Logs in to, in order": its step in the preset (blank for a login not in it), its
/// kind's symbol, its name and kind, and the button that adds it to the preset or removes it.
private struct PresetLoginRow: View {
    let login: Login
    let number: Int?
    let action: PresetMemberAction
    let systemImage: String
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(number.map(String.init) ?? "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .trailing)
                Image(systemName: loginKindSymbolName(login.kind))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(login.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(loginKindName(login.kind))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Button(action.label, systemImage: systemImage, action: perform)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(action.help)
        }
    }
}
