import PrinceClockInCore
import SwiftUI

/// One pane of the Settings window's sidebar.
enum SettingsPane: String, CaseIterable, Identifiable {
    case logins, presets, notifications, general, about

    var id: Self { self }

    var title: String {
        switch self {
        case .logins: "Logins"
        case .presets: "Presets"
        case .notifications: "Notifications"
        case .general: "General"
        case .about: "About"
        }
    }

    var symbolName: String {
        switch self {
        case .logins: "person.badge.key"
        case .presets: "list.bullet"
        case .notifications: "bell"
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
    let loginsPaneRequest: LoginsPaneRequest
    @AppStorage(SettingsView.paneKey) private var pane: SettingsPane = .logins

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: paneSelection) { pane in
                Label(pane.title, systemImage: pane.symbolName)
            }
        } detail: {
            switch pane {
            case .logins: LoginsSettings(appModel: appModel, request: loginsPaneRequest)
            case .presets: PresetsSettings(coordinator: appModel.coordinator)
            case .notifications: NotificationsSettings(appModel: appModel)
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

// MARK: Fields

/// A text field that hands its trimmed text to `commit` when submitted, when it loses focus, or
/// when it goes away (its window closes, or its pane or form is replaced), not on every keystroke,
/// so a command is approved and saved only once it is typed out. `commit` returns whether it took
/// the text; if not, the field shows `text` again. `prompt`, when given, is the empty field's
/// placeholder.
struct CommitField: View {
    let title: String
    let text: String
    let prompt: String?
    let commit: (String) -> Bool
    @State private var draft: String
    @FocusState private var isFocused: Bool

    init(_ title: String, text: String, prompt: String? = nil, commit: @escaping (String) -> Bool) {
        self.title = title
        self.text = text
        self.prompt = prompt
        self.commit = commit
        _draft = State(initialValue: text)
    }

    var body: some View {
        TextField(title, text: $draft, prompt: prompt.map { Text($0) })
            .focused($isFocused)
            .onSubmit(save)
            .onChange(of: isFocused) { _, isFocused in
                if !isFocused { save() }
            }
            // Closing the window while the field is focused ends no focus first.
            .onDisappear(perform: save)
            .onChange(of: text) { _, text in draft = text }
    }

    private func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != text, !commit(trimmed) { draft = text }
    }
}

/// A secondary caption under a field.
struct SettingsNote: View {
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

// MARK: Notifications

/// Settings → Notifications: how long before expiry a login is notified, the working hours
/// notifications wait for, and whether notifications are on. The permission is read again when the
/// pane appears and when the app becomes active, as after the user changes it in System Settings.
private struct NotificationsSettings: View {
    let appModel: AppModel

    var body: some View {
        let notifications = notificationsSetting(areOff: appModel.notificationsAreOff)
        Form {
            Section {
                DurationPopUp(
                    title: "Notify before a login expires", listed: listedNotificationLeadTimes,
                    value: \.notificationLeadTime, coordinator: appModel.coordinator)
            }
            WorkingHoursSection(coordinator: appModel.coordinator, calendar: .current)
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Notifications") {
                        HStack {
                            Text(notifications.state)
                            Button("Open System Settings…") { NSWorkspace.shared.open(AppLinks.notificationSettings) }
                                .controlSize(.small)
                        }
                    }
                    if let note = notifications.note { SettingsNote(note) }
                }
            }
        }
        .formStyle(.grouped)
        .task { await appModel.refreshNotificationPermission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await appModel.refreshNotificationPermission() }
        }
    }
}

/// Settings → Notifications' working hours: the toggle, and while it is on, the hours and the days
/// they start on. The last day picked can't be unpicked, so the hours always name one.
private struct WorkingHoursSection: View {
    let coordinator: Coordinator
    let calendar: Calendar

    var body: some View {
        let hours = coordinator.model.state.settings.workingHours
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Only notify during working hours", isOn: isOn)
                SettingsNote("Notifications from outside these hours arrive when they start.")
            }
            if hours.isOn {
                DatePicker("From", selection: clockTime(\.startMinute), displayedComponents: .hourAndMinute)
                VStack(alignment: .leading, spacing: 4) {
                    DatePicker("To", selection: clockTime(\.endMinute), displayedComponents: .hourAndMinute)
                    if hours.endMinute <= hours.startMinute { SettingsNote("They end the next day.") }
                }
                LabeledContent("Days") {
                    HStack(spacing: 4) {
                        ForEach(weekdaysInDisplayOrder(calendar: calendar), id: \.self) { weekday in
                            let isLastPicked = hours.weekdays == [weekday]
                            let toggle = Toggle(calendar.shortWeekdaySymbols[weekday - 1], isOn: day(weekday))
                                .toggleStyle(.button)
                                .disabled(isLastPicked)
                                .accessibilityLabel(calendar.weekdaySymbols[weekday - 1])
                            if isLastPicked { toggle.help("At least one day stays picked.") } else { toggle }
                        }
                    }
                }
            }
        }
    }

    private func update(_ change: (inout WorkingHours) -> Void) {
        var settings = coordinator.model.state.settings
        change(&settings.workingHours)
        coordinator.updateSettings(settings)
    }

    private var isOn: Binding<Bool> {
        Binding(
            get: { coordinator.model.state.settings.workingHours.isOn },
            set: { isOn in update { $0.isOn = isOn } })
    }

    /// A minute of the day as today's date at that time, which is what a time picker edits.
    private func clockTime(_ value: WritableKeyPath<WorkingHours, Int>) -> Binding<Date> {
        Binding(
            get: {
                let minute = coordinator.model.state.settings.workingHours[keyPath: value]
                return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: .now)
                    ?? calendar.startOfDay(for: .now)
            },
            set: { date in
                let parts = calendar.dateComponents([.hour, .minute], from: date)
                update { $0[keyPath: value] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0) }
            })
    }

    private func day(_ weekday: Int) -> Binding<Bool> {
        Binding(
            get: { coordinator.model.state.settings.workingHours.weekdays.contains(weekday) },
            set: { isPicked in
                update { hours in
                    if isPicked { hours.weekdays.insert(weekday) } else { hours.weekdays.remove(weekday) }
                }
            })
    }
}

/// A setting chosen from a short list of times, stored in the settings in seconds.
private struct DurationPopUp: View {
    let title: String
    let listed: [TimeInterval]
    let value: WritableKeyPath<PrinceClockInCore.Settings, TimeInterval>
    let coordinator: Coordinator

    var body: some View {
        let stored = coordinator.model.state.settings[keyPath: value]
        let selection = Binding<TimeInterval>(
            get: { stored },
            set: { duration in
                var settings = coordinator.model.state.settings
                settings[keyPath: value] = duration
                coordinator.updateSettings(settings)
            })
        Picker(title, selection: selection) {
            ForEach(durationOptions(listed, showing: stored), id: \.self) { duration in
                Text(sessionLengthText(duration)).tag(duration)
            }
        }
        .pickerStyle(.menu)
    }
}

// MARK: General

/// Settings → General: Launch at login and Login timeout.
/// The login item's status is read again when the pane appears and when the app becomes active,
/// since the user can change it in System Settings.
private struct GeneralSettings: View {
    let appModel: AppModel
    @State private var launchAtLoginStatus = LaunchAtLoginStatus.off
    @State private var launchAtLoginFailure: LaunchAtLoginFailure?

    var body: some View {
        let launchAtLogin = launchAtLoginSetting(status: launchAtLoginStatus, failure: launchAtLoginFailure)
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Launch at login", isOn: launchAtLoginBinding(isOn: launchAtLogin.isOn))
                    switch launchAtLogin.note {
                    case .needsApproval(let note):
                        HStack {
                            SettingsNote(note)
                            Spacer()
                            Button("Open…", action: LaunchAtLogin.openLoginItemsSettings)
                                .controlSize(.small)
                        }
                    case .failed(let note):
                        SettingsNote(note)
                    case nil:
                        EmptyView()
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    DurationPopUp(
                        title: "Login timeout", listed: listedLoginTimeouts, value: \.loginTimeout,
                        coordinator: appModel.coordinator)
                    SettingsNote("A login that takes longer than the login timeout is stopped and marked failed.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLoginStatus = LaunchAtLogin.status }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLoginStatus = LaunchAtLogin.status
        }
    }

    /// Reads the system's answer back after each change, since registering can need the user's
    /// approval in System Settings.
    private func launchAtLoginBinding(isOn: Bool) -> Binding<Bool> {
        Binding(
            get: { isOn },
            set: { enabled in
                do {
                    try LaunchAtLogin.setEnabled(enabled)
                    launchAtLoginFailure = nil
                } catch {
                    launchAtLoginFailure = LaunchAtLoginFailure(turningOn: enabled, reason: error.localizedDescription)
                }
                launchAtLoginStatus = LaunchAtLogin.status
            })
    }
}

// MARK: About

/// Settings → About: the app's icon, name, version and tagline with Check for Updates…, its links,
/// and what it connects to.
private struct AboutSettings: View {
    private static let iconSize: CGFloat = 64

    let updater: Updater

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: Self.iconSize, height: Self.iconSize)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PrinceClockIn")
                            .font(.title2.bold())
                        Text(version)
                            .foregroundStyle(.secondary)
                        Text("Your command-line logins, before they expire.")
                    }
                    Spacer()
                    Button("Check for Updates…") { updater.checkForUpdates() }
                }
            }
            Section {
                HStack(spacing: 16) {
                    Link("Report an Issue…", destination: AppLinks.reportIssue)
                    Link("Website", destination: AppLinks.website)
                    Button("Third-Party Notices…", action: openThirdPartyNotices)
                        .buttonStyle(.link)
                }
                .foregroundStyle(Color("Link"))
                Text(
                    "No analytics or crash reports. PrinceClockIn's only connection is the daily update check; "
                        + "the CLIs it runs make their own.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        return versionText(
            marketingVersion: info?["CFBundleShortVersionString"] as? String ?? "?",
            build: info?["CFBundleVersion"] as? String ?? "?")
    }

    /// Opens the bundled licenses in the user's text viewer.
    private func openThirdPartyNotices() {
        guard let notices = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") else { return }
        NSWorkspace.shared.open(notices)
    }
}
