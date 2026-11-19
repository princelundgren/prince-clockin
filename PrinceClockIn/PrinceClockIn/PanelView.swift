import PrinceClockInCore
import SwiftUI

/// The menu bar panel: notices, custom logins waiting for approval, the running batch, one row per
/// login, the log-in actions and the footer.
struct PanelView: View {
    let appModel: AppModel
    let updater: Updater
    let openSettings: () -> Void
    @State private var selection: Set<UUID> = []

    private var coordinator: Coordinator { appModel.coordinator }
    private var logins: [Login] { coordinator.model.state.logins }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            notices
            ForEach(pendingLogins) { login in
                PendingApprovalRow(login: login, coordinator: coordinator)
            }
            if let batch = coordinator.batch {
                BatchSection(batch: batch, coordinator: coordinator)
            }
            if logins.isEmpty {
                Text("No logins tracked yet. Add them in Settings.")
                    .foregroundStyle(.secondary)
            }
            ForEach(logins) { login in
                LoginRow(login: login, coordinator: coordinator, isSelected: selectionBinding(for: login.id))
            }
            if !logins.isEmpty {
                Divider()
                actions
            }
            if let version = updater.updateVersion {
                Divider()
                HStack {
                    Text(updateLineText(version: version, isRelaunchPostponed: false))
                    Spacer()
                    Button("View…") { updater.checkForUpdates() }
                }
            }
            Divider()
            footer
        }
        .padding()
        .frame(width: 320)
    }

    @ViewBuilder private var notices: some View {
        if let backup = coordinator.loadNotice {
            Notice("The settings file couldn't be read, so it was set aside as \(backup.lastPathComponent) and the app started empty.")
        }
        if appModel.notificationsAreOff {
            Notice("Notifications are off, so only the menu bar warns before a login expires. Turn them on in System Settings → Notifications.")
        }
        if let saveFailure = coordinator.saveFailure {
            Notice("Changes couldn't be saved: \(saveFailure)")
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !coordinator.model.state.presets.isEmpty {
                FlowButtons(presets: coordinator.model.state.presets) { preset in
                    coordinator.logIn(coordinator.model.logins(in: preset).map(\.id))
                }
            }
            HStack {
                Button("Log in to selected") {
                    coordinator.logIn(logins.map(\.id).filter(selection.contains))
                    selection.removeAll()
                }
                .disabled(selection.isEmpty)
                Button("Log in to expiring") {
                    coordinator.logIn(coordinator.model.dueLogins(now: coordinator.now).map(\.id))
                }
                .disabled(coordinator.model.dueLogins(now: coordinator.now).isEmpty)
                Button("Check now") {
                    Task { await coordinator.checkNow() }
                }
                .disabled(!coordinator.canCheckDatabricksNow)
                .help("Ask the Databricks CLI whether each Databricks login is still valid")
            }
        }
    }

    /// Two rows, since one doesn't fit the panel's width.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Link("Report an issue", destination: AppLinks.reportIssue)
                Link("Website", destination: AppLinks.website)
            }
            HStack {
                Button("Check for Updates…") { updater.checkForUpdates() }
                Spacer()
                Button("Settings…", action: openSettings)
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .font(.callout)
    }

    private var pendingLogins: [Login] {
        coordinator.pendingApprovals.compactMap { id in logins.first { $0.id == id } }
    }

    private func selectionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selection.contains(id) },
            set: { isOn in
                if isOn { selection.insert(id) } else { selection.remove(id) }
            })
    }
}

private struct Notice: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One button per preset, wrapping onto as many lines as they need.
private struct FlowButtons: View {
    let presets: [Preset]
    let action: (Preset) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack { buttons }
            VStack(alignment: .leading) { buttons }
        }
    }

    private var buttons: some View {
        ForEach(presets) { preset in
            Button(preset.name) { action(preset) }
        }
    }
}

private struct BatchSection: View {
    let batch: BatchProgress
    let coordinator: Coordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: Double(batch.position - 1), total: Double(batch.total)) {
                Text("Logging in \(batch.position) of \(batch.total)")
            }
            HStack {
                if let id = coordinator.waitingCustomID,
                   let login = coordinator.model.state.logins.first(where: { $0.id == id }) {
                    Text("\(login.displayName) is waiting for you")
                    Button("Done") { coordinator.confirmCustomDone(id: id) }
                }
                Spacer()
                Button("Cancel") { coordinator.cancelBatch() }
            }
        }
    }
}

private struct PendingApprovalRow: View {
    let login: Login
    let coordinator: Coordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Run this command for \(login.displayName)?")
                .font(.headline)
            if case .custom(let command?) = login.kind {
                Text(command)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Run it") { coordinator.approveAndLogIn(login.id) }
                Button("Cancel") { coordinator.dismissPendingApproval(id: login.id) }
            }
        }
    }
}
