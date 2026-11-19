import PrinceClockInCore
import SwiftUI

/// Settings → Logins: the tracked logins with − below them and Check Databricks Now in the
/// header, then the selected login's form.
struct LoginsSettings: View {
    let appModel: AppModel
    @State private var selection: UUID?
    @State private var candidates: (aws: [String], databricks: [DatabricksProfile]) = ([], [])
    /// The login just added from the config files, which shows its Set Timer form.
    @State private var justAdded: UUID?
    @State private var customName = ""
    @State private var customCommand = ""
    /// What − asks before removing a login that is in a preset, while it asks.
    @State private var removal: RemoveLoginConfirmation?

    private var coordinator: Coordinator { appModel.coordinator }
    private var logins: [Login] { coordinator.model.state.logins }
    private var selected: Login? { logins.first { $0.id == selection } }

    var body: some View {
        Form {
            Section {
                List(selection: $selection) {
                    ForEach(logins) { login in
                        LoginRow(login: login, coordinator: coordinator)
                            .tag(login.id)
                    }
                }
                .frame(minHeight: 160)
                listButtons
            } header: {
                header
            }
            if let selected {
                LoginForm(login: selected, appModel: appModel, isJustAdded: selected.id == justAdded) {
                    justAdded = nil
                }
                .id(selected.id)
            }
            Section("Found in your config files") {
                if candidates.aws.isEmpty && candidates.databricks.isEmpty {
                    Text("No untracked AWS SSO sessions or Databricks profiles.")
                        .foregroundStyle(.secondary)
                }
                ForEach(candidates.aws, id: \.self) { session in
                    candidateRow("AWS SSO session \(session)") { add(.awsSSOSession(name: session)) }
                }
                ForEach(candidates.databricks, id: \.name) { profile in
                    candidateRow("Databricks profile \(profile.name)") { add(.databricksProfile(profile)) }
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
        .alert(removal?.title ?? "", isPresented: isAskingToRemove, presenting: removal) { removal in
            Button("Remove", role: .destructive) { remove(removal.loginID) }
            Button("Cancel", role: .cancel) {}
        } message: { removal in
            Text(removal.message)
        }
        .onChange(of: selection) { old, _ in
            // The prompt after adding is asked once: moving off the login ends it.
            if old == justAdded { justAdded = nil }
        }
        .onAppear(perform: refreshCandidates)
    }

    private var header: some View {
        HStack {
            Text("Logins")
            Spacer()
            Button("Check Databricks Now") {
                Task { await coordinator.checkNow() }
            }
            .controlSize(.small)
            .disabled(!coordinator.canCheckDatabricksNow)
            .help("Ask the Databricks CLI whether each Databricks login is still valid")
        }
    }

    private var listButtons: some View {
        HStack {
            Button("Remove Login", systemImage: "minus", action: removeSelected)
                .labelStyle(.iconOnly)
                .disabled(selected == nil)
                .help(removeLoginHelp(for: selected))
            Spacer()
        }
        .buttonStyle(.borderless)
    }

    /// Removes a login in no preset at once, and asks first for one in a preset.
    private func removeSelected() {
        guard let selected else { return }
        if let confirmation = removeLoginConfirmation(
            for: selected, presets: coordinator.model.state.presets, locale: .current) {
            removal = confirmation
        } else {
            remove(selected.id)
        }
    }

    private func remove(_ id: UUID) {
        coordinator.removeLogin(id: id)
        if selection == id { selection = nil }
        if justAdded == id { justAdded = nil }
    }

    private var isAskingToRemove: Binding<Bool> {
        Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })
    }

    private func candidateRow(_ title: String, add: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button("Add", action: add)
        }
    }

    private func add(_ candidate: AddLoginCandidate) {
        let login = candidate.login()
        coordinator.addLogin(login)
        selection = login.id
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

/// A tracked login in the list: its kind's symbol, its name and its subtitle.
private struct LoginRow: View {
    let login: Login
    let coordinator: Coordinator

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: loginKindSymbolName(login.kind))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(login.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(loginRowSubtitle(for: login, now: coordinator.now, locale: .current, calendar: .current))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// The selected login's form: Name and Session length for every kind, then what its kind adds.
private struct LoginForm: View {
    let login: Login
    let appModel: AppModel
    let isJustAdded: Bool
    let closePrompt: () -> Void
    @FocusState private var focus: PanelFocus?
    @State private var sessionLengthDraft: SessionLengthFieldDraft?
    /// Custom… was chosen, so its field shows even for a listed length until another is chosen or
    /// the length becomes unknown.
    @State private var isCustomChosen = false

    private var coordinator: Coordinator { appModel.coordinator }

    private var showsCustomLength: Bool {
        isCustomChosen || PrinceClockInCore.sessionLengthChoice(for: login.sessionLength) == .custom
    }

    /// The pop-up's choice: a listed length or No timer is stored at once; Custom… shows the
    /// hours field, which stores on Return or when focus leaves it.
    private var sessionLengthChoice: Binding<SessionLengthChoice> {
        Binding(
            get: { showsCustomLength ? .custom : PrinceClockInCore.sessionLengthChoice(for: login.sessionLength) },
            set: { choice in
                switch choice {
                case .length(let length): store(length)
                case .custom: isCustomChosen = true
                case .noTimer: store(nil)
                }
            })
    }

    private func store(_ length: TimeInterval?) {
        isCustomChosen = false
        sessionLengthDraft = nil
        // Only listed lengths and No timer, which the core accepts.
        try? coordinator.setSessionLength(id: login.id, to: length)
    }

    var body: some View {
        let form = loginSettingsForm(
            for: login, paths: coordinator.configPaths, home: appModel.homeDirectory, now: coordinator.now,
            locale: .current, calendar: .current)
        if isJustAdded {
            Section {
                Text("Already logged in? Set its timer now, or skip.")
                JustAddedSetTimer(login: login, coordinator: coordinator, onClose: closePrompt)
            }
        }
        Section(login.displayName) {
            VStack(alignment: .leading, spacing: 4) {
                CommitField("Name", text: login.displayName) { name in
                    guard !name.isEmpty else { return false }
                    coordinator.rename(id: login.id, to: name)
                    return true
                }
                SettingsNote(form.nameNote)
            }
            if let source = form.source {
                LabeledContent(source.label, value: source.value)
            }
            SessionLengthPopUp(selection: sessionLengthChoice)
            if showsCustomLength {
                SessionLengthField(
                    login: login, coordinator: coordinator, focus: $focus, draft: $sessionLengthDraft,
                    title: "Custom length")
            }
            if let lastCheck = form.lastCheck {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Last check", value: lastCheck.text)
                    if let checkNote = lastCheck.note { SettingsNote(checkNote) }
                }
            }
            if case .custom(let command) = login.kind, let commandNote = form.commandNote {
                VStack(alignment: .leading, spacing: 4) {
                    CommitField("Command", text: command ?? "", prompt: "Optional") { command in
                        coordinator.setCommand(id: login.id, to: command.isEmpty ? nil : command)
                        return true
                    }
                    .font(.body.monospaced())
                    SettingsNote(commandNote)
                }
            }
        }
        // An emptied Custom… field makes the length unknown, which the pop-up shows as No timer,
        // also when it was unknown before; the field's draft goes once it is stored.
        .onChange(of: login.sessionLength) { _, length in
            if length == nil { isCustomChosen = false }
        }
        .onChange(of: sessionLengthDraft == nil) { _, isStored in
            if isStored, login.sessionLength == nil { isCustomChosen = false }
        }
    }
}

/// A secondary caption under a field.
private struct SettingsNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
