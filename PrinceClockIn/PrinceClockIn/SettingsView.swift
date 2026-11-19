import PrinceClockInCore
import SwiftUI

/// One pane of the Settings window's sidebar.
enum SettingsPane: String, CaseIterable, Identifiable {
    case logins, presets, warnings, general, about

    var id: Self { self }

    var title: String {
        switch self {
        case .logins: "Logins"
        case .presets: "Presets"
        case .warnings: "Warnings"
        case .general: "General"
        case .about: "About"
        }
    }

    var symbolName: String {
        switch self {
        case .logins: "person.badge.key"
        case .presets: "list.bullet"
        case .warnings: "bell"
        case .general: "gearshape"
        case .about: "info.circle"
        }
    }
}

/// The Settings window's content: a sidebar of panes beside the chosen pane, which is restored
/// the next time the window opens.
struct SettingsView: View {
    static let minimumSize = CGSize(width: 620, height: 540)
    static let idealSize = CGSize(width: 760, height: 640)
    /// The user defaults key of the pane shown.
    static let paneKey = "settingsPane"

    let appModel: AppModel
    let updater: Updater
    @AppStorage(SettingsView.paneKey) private var pane: SettingsPane = .logins

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: paneSelection) { pane in
                Label(pane.title, systemImage: pane.symbolName)
            }
        } detail: {
            switch pane {
            case .logins: LoginsSettings(coordinator: appModel.coordinator)
            case .presets: PresetsSettings(coordinator: appModel.coordinator)
            case .warnings: WarningsSettings(coordinator: appModel.coordinator)
            case .general: GeneralSettings(appModel: appModel)
            case .about: AboutSettings(updater: updater)
            }
        }
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
    }

    /// The sidebar's selection, which can't be cleared, since a pane is always shown.
    private var paneSelection: Binding<SettingsPane?> {
        Binding(get: { pane }, set: { if let selected = $0 { pane = selected } })
    }
}

// MARK: Logins

private struct LoginsSettings: View {
    let coordinator: Coordinator
    @State private var candidates: (aws: [String], databricks: [DatabricksProfile]) = ([], [])
    /// The login just added from the config files, which shows its Set Timer form.
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
                            JustAddedSetTimer(login: login, coordinator: coordinator) { justAdded = nil }
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
        Task { candidates = await coordinator.discoverCandidates() }
    }
}

/// Set Timer for a login just added, with Skip in place of Cancel and the panel's Return and
/// Escape; `onClose` runs after Skip or Set.
private struct JustAddedSetTimer: View {
    let login: Login
    let coordinator: Coordinator
    let onClose: () -> Void
    @State private var draft: SetTimerDraft
    @FocusState private var focus: PanelFocus?

    init(login: Login, coordinator: Coordinator, onClose: @escaping () -> Void) {
        self.login = login
        self.coordinator = coordinator
        self.onClose = onClose
        _draft = State(initialValue: SetTimerDraft(for: login, now: coordinator.now, locale: .current))
    }

    var body: some View {
        SetTimerForm(
            id: login.id, draft: $draft, coordinator: coordinator, note: nil, cancelTitle: "Skip",
            defaults: PanelDefaults(keys: .setTimerAlone(id: login.id, isEditingText: focus?.isTextField ?? false)),
            focus: $focus, onClose: onClose)
    }
}

private struct LoginSettingsRow: View {
    let login: Login
    let coordinator: Coordinator
    @FocusState private var focus: PanelFocus?
    @State private var sessionLengthDraft: SessionLengthFieldDraft?

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
            SessionLengthField(login: login, coordinator: coordinator, focus: $focus, draft: $sessionLengthDraft)
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

// MARK: Warnings

private struct WarningsSettings: View {
    let coordinator: Coordinator

    var body: some View {
        Form {
            MinutesField(title: "Warn before expiry", value: \.warningLeadTime, coordinator: coordinator)
        }
        .formStyle(.grouped)
    }
}

/// A setting in minutes, from 5 minutes to a day, stored in the settings in seconds.
private struct MinutesField: View {
    private static let secondsPerMinute: Double = 60

    let title: String
    let value: WritableKeyPath<PrinceClockInCore.Settings, TimeInterval>
    let coordinator: Coordinator

    var body: some View {
        let minutes = Binding<Double>(
            get: { coordinator.model.state.settings[keyPath: value] / Self.secondsPerMinute },
            set: { minutes in
                var settings = coordinator.model.state.settings
                settings[keyPath: value] = (minutes * Self.secondsPerMinute).rounded(.down)
                coordinator.updateSettings(settings)
            })
        LabeledContent(title) {
            Stepper(value: minutes, in: 5...24 * 60, step: 5) {
                Text("\(Int(minutes.wrappedValue)) min")
                    .monospacedDigit()
            }
        }
    }
}

// MARK: General

private struct GeneralSettings: View {
    let appModel: AppModel
    @State private var launchesAtLogin = false
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section {
                MinutesField(title: "Login timeout", value: \.loginTimeout, coordinator: appModel.coordinator)
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

// MARK: About

private struct AboutSettings: View {
    let updater: Updater

    var body: some View {
        Form {
            Section {
                LabeledContent("PrinceClockIn", value: version)
                Button("Check for Updates…") { updater.checkForUpdates() }
            }
            Section {
                Link("Report an Issue…", destination: AppLinks.reportIssue)
                Link("Website", destination: AppLinks.website)
                Button("Third-Party Notices…", action: openThirdPartyNotices)
            }
        }
        .formStyle(.grouped)
    }

    /// "v1.0.0 (42)": the marketing version and the build number.
    private var version: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(marketing) (\(build))"
    }

    /// Opens the bundled licenses in the user's text viewer.
    private func openThirdPartyNotices() {
        guard let notices = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") else { return }
        NSWorkspace.shared.open(notices)
    }
}
