import AppKit
import PrinceClockInCore
import SwiftUI

/// Settings → Logins: a section headed by Check Now, holding the tracked logins, which a drag
/// reorders for the panel, + and − below them and the login timeout below those; then the selected
/// login's form, or New custom login.
struct LoginsSettings: View {
    let appModel: AppModel
    let request: LoginsPaneRequest
    @State private var selection: UUID?
    /// What discovery found that isn't tracked; `nil` while the config files are read.
    @State private var candidates: DiscoveredLogins?
    @State private var isAddingCustomLogin = false
    @State private var addMenu = AddMenuPresenter()
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
                    .onMove { offsets, destination in
                        var order = ListOrder(logins.map(\.id))
                        order.move(fromOffsets: offsets, toOffset: destination)
                        coordinator.setLoginOrder(order.ids)
                    }
                }
                .frame(minHeight: 160)
                .accessibilityLabel("Logins")
                listButtons
                VStack(alignment: .leading, spacing: 4) {
                    DurationPopUp(
                        title: "Login timeout", listed: listedLoginTimeouts, value: \.loginTimeout,
                        coordinator: coordinator)
                    SettingsNote("A login that takes longer than the login timeout is stopped and marked failed.")
                }
            } header: {
                header
            }
            if isAddingCustomLogin {
                NewCustomLoginForm(onClose: closeNewCustomLogin)
            } else if let selected {
                LoginForm(login: selected, appModel: appModel)
                    .id(selected.id)
            }
        }
        .formStyle(.grouped)
        .alert(removal?.title ?? "", isPresented: isAskingToRemove, presenting: removal) { removal in
            Button("Remove", role: .destructive) { remove(removal.loginID) }
            Button("Cancel", role: .cancel) {}
        } message: { removal in
            Text(removal.message)
        }
        .onChange(of: selection) { _, new in
            if new != nil { isAddingCustomLogin = false }
        }
        .task(id: TrackedConfigNames(logins: logins)) { await discover() }
        .onChange(of: request.isAddMenuPending, initial: true) { openRequestedAddMenu() }
        // A request the pane didn't get to before it went stays unanswered, never opening later.
        .onDisappear { request.isAddMenuPending = false }
    }

    private var header: some View {
        HStack {
            Text("Logins")
            Spacer()
            Button("Check Now") {
                Task { await coordinator.checkNow() }
            }
            .controlSize(.small)
            .disabled(!coordinator.canCheckNow)
            .help("Ask the Databricks, gcloud and Azure CLIs whether each of their logins is still valid.")
        }
    }

    private var listButtons: some View {
        HStack(spacing: 4) {
            Button("Add Login", systemImage: "plus") { addMenu.show(addMenuItems, choose: choose) }
                .labelStyle(.iconOnly)
                .background(AddMenuAnchor(presenter: addMenu))
                .help("Add a login.")
            Button("Remove Login", systemImage: "minus", action: removeSelected)
                .labelStyle(.iconOnly)
                .disabled(selected == nil)
                .help(removeLoginHelp(for: selected))
            Spacer()
        }
        .buttonStyle(.borderless)
    }

    private var addMenuItems: [AddMenuItem] {
        PrinceClockInCore.addMenu(found: candidates)
    }

    /// Reads the config files for the + menu when the pane appears and whenever a tracked AWS SSO
    /// session, Databricks profile, gcloud account or Azure tenant is added or removed, a new read
    /// cancelling the one before; a cancelled read's answer is dropped.
    private func discover() async {
        candidates = nil
        let found = await coordinator.discoverCandidates()
        guard !Task.isCancelled else { return }
        candidates = found
        openRequestedAddMenu()
    }

    /// Opens the + menu for the panel's Add Logins… once the config files are read and the pane is
    /// in its window, after the current update.
    private func openRequestedAddMenu() {
        guard request.isAddMenuPending, candidates != nil, addMenu.anchor?.window != nil else { return }
        request.isAddMenuPending = false
        Task { addMenu.show(addMenuItems, choose: choose) }
    }

    /// A found login is tracked at once and selected; Custom Login… opens New custom login.
    private func choose(_ item: AddMenuItem) {
        switch item {
        case .found(let candidate):
            let login = candidate.login()
            coordinator.addLogin(login)
            selection = login.id
        case .customLogin:
            selection = nil
            isAddingCustomLogin = true
        case .header, .note:
            break
        }
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
    }

    private var isAskingToRemove: Binding<Bool> {
        Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })
    }

    /// Add hands over the new login, Cancel `nil`. Return can reach Add twice, from a field and as
    /// Add's key equivalent, so only the first closes the form.
    private func closeNewCustomLogin(adding login: Login?) {
        guard isAddingCustomLogin else { return }
        isAddingCustomLogin = false
        guard let login else { return }
        coordinator.addLogin(login)
        selection = login.id
    }
}

/// What the rest of the app asks of Settings → Logins.
@MainActor
@Observable
final class LoginsPaneRequest {
    /// The panel's Add Logins… asked for the + menu, which the pane opens and then clears this.
    var isAddMenuPending = false
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

/// The selected login's form, headed by its kind's symbol, name and kind: Name and Session length
/// for every kind, then what its kind adds.
private struct LoginForm: View {
    let login: Login
    let appModel: AppModel
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
        Section {
            VStack(alignment: .leading, spacing: 4) {
                CommitField("Name", text: login.displayName) { name in
                    guard !name.isEmpty else { return false }
                    coordinator.rename(id: login.id, to: name)
                    return true
                }
                .textFieldStyle(.roundedBorder)
                if let nameNote = form.nameNote { SettingsNote(nameNote) }
            }
            if let source = form.source {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent(source.label, value: source.value)
                    SettingsNote(source.note)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                SessionLengthPopUp(selection: sessionLengthChoice)
                SettingsNote(sessionLengthNote(for: login.kind, choice: sessionLengthChoice.wrappedValue))
            }
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
        } header: {
            HStack(spacing: 10) {
                Image(systemName: loginKindSymbolName(login.kind))
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(login.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(loginKindName(login.kind))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
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

/// New custom login: Name, Command (optional) and Session length, with Cancel and Add. It opens
/// with Name focused; Return adds from anywhere in the form and Escape cancels; a Custom… length
/// the core refuses stays, with the refusal under it, until it changes.
private struct NewCustomLoginForm: View {
    let onClose: (_ adding: Login?) -> Void
    @State private var draft = NewCustomLoginDraft()
    @State private var refusal: SessionLengthRefusal?
    @FocusState private var isNameFocused: Bool

    var body: some View {
        Section("New custom login") {
            TextField("Name", text: $draft.name)
                .focused($isNameFocused)
                .onSubmit(add)
            VStack(alignment: .leading, spacing: 4) {
                TextField("Command", text: $draft.command, prompt: Text("Optional"))
                    .font(.body.monospaced())
                    .onSubmit(add)
                SettingsNote(customCommandNote)
                if let noCommandNote = draft.noCommandNote {
                    SettingsNote(noCommandNote)
                }
            }
            SessionLengthPopUp(selection: $draft.sessionLength)
            if draft.sessionLength == .custom {
                VStack(alignment: .leading, spacing: 2) {
                    LabeledContent("Custom length") {
                        HStack(spacing: 4) {
                            NumberField(label: "Session length in hours", text: $draft.customHours, prompt: "Hours")
                                .onSubmit(add)
                            Text("hours")
                        }
                    }
                    if let refusal {
                        Text(refusal.message)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { onClose(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.check(locale: .current) == .needsName)
            }
        }
        .onChange(of: draft.customHours) { refusal = nil }
        .onChange(of: draft.sessionLength) { refusal = nil }
        // The window has already appeared, so `defaultFocus` wouldn't apply; setting the focus
        // state moves focus.
        .onAppear { isNameFocused = true }
    }

    private func add() {
        switch draft.check(locale: .current) {
        case .needsName: break
        case .refused(let refusal): self.refusal = refusal
        case .ready(let login): onClose(login)
        }
    }
}

/// Pops up the + menu below the view it is anchored to. It is an AppKit menu, since SwiftUI's
/// `Menu` can't be opened from code.
@MainActor
final class AddMenuPresenter: NSObject {
    /// The + button's frame, as an AppKit view.
    weak var anchor: NSView?
    private var items: [AddMenuItem] = []
    private var choose: (AddMenuItem) -> Void = { _ in }

    /// Shows `items`, a section header and a note as lines that can't be chosen and a found login
    /// with its kind beside it; `choose` gets the item chosen. Both are let go once the menu is
    /// done with them, since `choose` holds the pane's state, which holds this presenter.
    func show(_ items: [AddMenuItem], choose: @escaping (AddMenuItem) -> Void) {
        guard let anchor else { return }
        self.items = items
        self.choose = choose
        let menu = NSMenu()
        for (index, item) in items.enumerated() {
            if item == .customLogin, index > 0 { menu.addItem(.separator()) }
            menu.addItem(menuItem(for: item, tag: index))
        }
        let bottom = anchor.isFlipped ? anchor.bounds.maxY : anchor.bounds.minY
        if !menu.popUp(positioning: nil, at: NSPoint(x: anchor.bounds.minX, y: bottom), in: anchor) {
            release()
        }
    }

    private func release() {
        items = []
        choose = { _ in }
    }

    private func menuItem(for item: AddMenuItem, tag: Int) -> NSMenuItem {
        switch item {
        case .header(let title):
            return .sectionHeader(title: title)
        case .note(let title):
            // With no action, the menu disables it.
            return NSMenuItem(title: title, action: nil, keyEquivalent: "")
        case .found, .customLogin:
            let menuItem = NSMenuItem(title: item.title, action: #selector(chosen), keyEquivalent: "")
            menuItem.target = self
            menuItem.tag = tag
            if let kind = item.kind {
                let font = NSFont.menuFont(ofSize: 0)
                let title = NSMutableAttributedString(string: item.title, attributes: [.font: font])
                title.append(NSAttributedString(
                    string: "  \(kind)", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
                menuItem.attributedTitle = title
            }
            return menuItem
        }
    }

    @objc private func chosen(_ sender: NSMenuItem) {
        let choose = choose
        let item = items[sender.tag]
        release()
        choose(item)
    }
}

/// Puts the + button's frame in AppKit, for the + menu to pop up from.
private struct AddMenuAnchor: NSViewRepresentable {
    let presenter: AddMenuPresenter

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        presenter.anchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
