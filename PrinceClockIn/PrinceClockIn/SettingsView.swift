import PrinceClockInCore
import SwiftUI

/// The settings window: the logins, the presets, and the general settings.
struct SettingsView: View {
    let appModel: AppModel

    var body: some View {
        TabView {
            Tab("Logins", systemImage: "person.badge.key") {
                LoginsSettings(coordinator: appModel.coordinator)
            }
            Tab("Presets", systemImage: "list.bullet") {
                PresetsSettings(coordinator: appModel.coordinator)
            }
            Tab("General", systemImage: "gearshape") {
                GeneralSettings(appModel: appModel)
            }
        }
        .frame(width: 560, height: 520)
    }
}

// MARK: Logins

private struct LoginsSettings: View {
    let coordinator: Coordinator
    @State private var candidates: (aws: [String], databricks: [DatabricksProfile]) = ([], [])
    /// The login just added from the config files, which shows its Set timer controls.
    @State private var justAdded: UUID?
    @State private var customName = ""
    @State private var customCommand = ""

    var body: some View {
        Form {
            Section("Tracked") {
                if coordinator.model.state.logins.isEmpty {
                    Text("None yet. Add one below.")
                        .foregroundStyle(.secondary)
                }
                ForEach(coordinator.model.state.logins) { login in
                    LoginSettingsRow(login: login, coordinator: coordinator)
                    if login.id == justAdded {
                        VStack(alignment: .leading) {
                            Text("Already logged in? Set its timer now, or skip.")
                                .font(.callout)
                            SetTimerControls(login: login, coordinator: coordinator) { justAdded = nil }
                            Button("Skip") { justAdded = nil }
                        }
                    }
                }
            }
            Section("Found in your config files") {
                if candidates.aws.isEmpty && candidates.databricks.isEmpty {
                    Text("No untracked AWS SSO sessions or Databricks profiles.")
                        .foregroundStyle(.secondary)
                }
                ForEach(candidates.aws, id: \.self) { session in
                    candidateRow("AWS SSO session \(session)") {
                        add(Login(
                            displayName: session, kind: .awsSSOSession(name: session),
                            sessionLength: Login.defaultSessionLength(for: .awsSSOSession(name: session))))
                    }
                }
                ForEach(candidates.databricks, id: \.name) { profile in
                    candidateRow("Databricks profile \(profile.name)") {
                        add(Login(
                            displayName: profile.name,
                            kind: .databricksProfile(name: profile.name, accountLevel: profile.accountLevel)))
                    }
                }
            }
            Section("Custom login") {
                TextField("Name", text: $customName)
                TextField("Command (optional)", text: $customCommand)
                    .font(.body.monospaced())
                Text("The command opens in Terminal. It is stored as plain text, so don't put a secret in it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Add custom login") { addCustom() }
                    .disabled(customName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshCandidates)
    }

    private func candidateRow(_ title: String, add: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button("Add", action: add)
        }
    }

    private func add(_ login: Login) {
        coordinator.addLogin(login)
        justAdded = login.id
        refreshCandidates()
    }

    private func addCustom() {
        let command = customCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        coordinator.addLogin(Login(
            displayName: customName.trimmingCharacters(in: .whitespaces),
            kind: .custom(command: command.isEmpty ? nil : command)))
        customName = ""
        customCommand = ""
    }

    private func refreshCandidates() {
        candidates = coordinator.discoverCandidates()
    }
}

private struct LoginSettingsRow: View {
    let login: Login
    let coordinator: Coordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                CommitField("Name", text: login.displayName) { name in
                    guard !name.isEmpty else { return false }
                    coordinator.rename(id: login.id, to: name)
                    return true
                }
                Button("Remove", role: .destructive) { coordinator.removeLogin(id: login.id) }
            }
            Text(kindDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            SessionLengthField(login: login, coordinator: coordinator)
            if case .custom(let command) = login.kind {
                CommitField("Command (optional)", text: command ?? "") { command in
                    coordinator.setCommand(id: login.id, to: command.isEmpty ? nil : command)
                    return true
                }
                .font(.body.monospaced())
            }
        }
        .padding(.vertical, 2)
    }

    private var kindDescription: String {
        switch login.kind {
        case .awsSSOSession(let name): "AWS SSO session \(name)"
        case .databricksProfile(let name, let accountLevel):
            accountLevel ? "Databricks account profile \(name), never checked" : "Databricks profile \(name)"
        case .custom: "Custom login"
        }
    }
}

/// A text field that hands its trimmed text to `commit` when submitted or when it loses focus,
/// not on every keystroke, so a command is approved and saved only once it is typed out. `commit`
/// returns whether it took the text; if not, the field shows `text` again.
private struct CommitField: View {
    let title: String
    let text: String
    let commit: (String) -> Bool
    @State private var draft: String
    @FocusState private var isFocused: Bool

    init(_ title: String, text: String, commit: @escaping (String) -> Bool) {
        self.title = title
        self.text = text
        self.commit = commit
        _draft = State(initialValue: text)
    }

    var body: some View {
        TextField(title, text: $draft)
            .focused($isFocused)
            .onSubmit(save)
            .onChange(of: isFocused) { _, isFocused in
                if !isFocused { save() }
            }
            .onChange(of: text) { _, text in draft = text }
    }

    private func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != text, !commit(trimmed) { draft = text }
    }
}

// MARK: Presets

private struct PresetsSettings: View {
    let coordinator: Coordinator

    private var logins: [Login] { coordinator.model.state.logins }

    var body: some View {
        Form {
            ForEach(coordinator.model.state.presets) { preset in
                Section {
                    PresetEditor(preset: preset, logins: logins, coordinator: coordinator)
                }
            }
            Section {
                Button("New preset") {
                    coordinator.savePreset(Preset(name: "New preset", loginIDs: []))
                }
                .disabled(logins.isEmpty)
            } footer: {
                Text("A preset logs in to its logins in the order listed, one at a time.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct PresetEditor: View {
    let preset: Preset
    let logins: [Login]
    let coordinator: Coordinator

    var body: some View {
        HStack {
            CommitField("Name", text: preset.name) { name in
                guard !name.isEmpty else { return false }
                save { $0.name = name }
                return true
            }
            Button("Remove preset", role: .destructive) { coordinator.removePreset(id: preset.id) }
        }
        ForEach(Array(members.enumerated()), id: \.element.id) { index, login in
            HStack {
                Text("\(index + 1). \(login.displayName)")
                Spacer()
                Button("Move up", systemImage: "chevron.up") { move(from: index, by: -1) }
                    .labelStyle(.iconOnly)
                    .disabled(index == 0)
                Button("Move down", systemImage: "chevron.down") { move(from: index, by: 1) }
                    .labelStyle(.iconOnly)
                    .disabled(index == members.count - 1)
                Button("Remove from preset", systemImage: "minus.circle") {
                    save { $0.loginIDs.removeAll { $0 == login.id } }
                }
                .labelStyle(.iconOnly)
            }
        }
        let others = logins.filter { !preset.loginIDs.contains($0.id) }
        if !others.isEmpty {
            Menu("Add login") {
                ForEach(others) { login in
                    Button(login.displayName) { save { $0.loginIDs.append(login.id) } }
                }
            }
            .fixedSize()
        }
    }

    /// The preset's logins in its order, skipping any no longer tracked.
    private var members: [Login] {
        coordinator.model.logins(in: preset)
    }

    private func move(from index: Int, by offset: Int) {
        var ids = members.map(\.id)
        ids.swapAt(index, index + offset)
        save { $0.loginIDs = ids }
    }

    private func save(_ change: (inout Preset) -> Void) {
        var edited = preset
        change(&edited)
        coordinator.savePreset(edited)
    }
}

// MARK: General

private struct GeneralSettings: View {
    private static let secondsPerMinute: Double = 60

    let appModel: AppModel
    @State private var launchesAtLogin = false
    @State private var launchAtLoginError: String?

    private var coordinator: Coordinator { appModel.coordinator }

    var body: some View {
        Form {
            Section {
                minutesField("Warn before expiry", value: \.warningLeadTime)
                minutesField("Login timeout", value: \.loginTimeout)
            }
            Section {
                Toggle("Launch at login", isOn: launchAtLoginBinding)
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .foregroundStyle(.red)
                }
            }
            Section {
                if appModel.notificationsAreOff {
                    Label(
                        "Notifications are off, so only the menu bar warns before a login expires. Turn them on in System Settings → Notifications.",
                        systemImage: "exclamationmark.triangle")
                }
                Text("Removing the icon from the menu bar quits PrinceClockIn, which stops its timers and notifications.")
                Text("Custom commands are stored as plain text in the settings file, so they must not contain secrets.")
            }
            .font(.callout)
        }
        .formStyle(.grouped)
        .onAppear { launchesAtLogin = LaunchAtLogin.isEnabled }
        .task { await appModel.refreshNotificationPermission() }
    }

    private func minutesField(_ title: String, value keyPath: WritableKeyPath<PrinceClockInCore.Settings, TimeInterval>) -> some View {
        let minutes = Binding<Double>(
            get: { coordinator.model.state.settings[keyPath: keyPath] / Self.secondsPerMinute },
            set: { minutes in
                var settings = coordinator.model.state.settings
                settings[keyPath: keyPath] = (minutes * Self.secondsPerMinute).rounded(.down)
                coordinator.updateSettings(settings)
            })
        return LabeledContent(title) {
            Stepper(value: minutes, in: 5...24 * 60, step: 5) {
                Text("\(Int(minutes.wrappedValue)) min")
                    .monospacedDigit()
            }
        }
    }

    /// Reads the system's answer back after each change, since registering can need the user's
    /// approval in System Settings.
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchesAtLogin },
            set: { enabled in
                do {
                    try LaunchAtLogin.setEnabled(enabled)
                    launchAtLoginError = nil
                } catch {
                    launchAtLoginError = error.localizedDescription
                }
                launchesAtLogin = LaunchAtLogin.isEnabled
            })
    }
}
