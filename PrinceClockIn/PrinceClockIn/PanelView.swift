import PrinceClockInCore
import SwiftUI

/// The menu bar panel: custom logins waiting for approval, one row per login, and Quit.
struct PanelView: View {
    let coordinator: Coordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(pendingLogins) { login in
                PendingApprovalRow(login: login, coordinator: coordinator)
            }
            if coordinator.model.state.logins.isEmpty {
                Text("No logins tracked yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(coordinator.model.state.logins) { login in
                LoginRow(login: login, coordinator: coordinator)
            }
            Divider()
            Button("Quit PrinceClockIn") { NSApplication.shared.terminate(nil) }
        }
        .padding()
        .frame(width: 320)
    }

    private var pendingLogins: [Login] {
        coordinator.pendingApprovals.compactMap { id in
            coordinator.model.state.logins.first { $0.id == id }
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

private struct LoginRow: View {
    let login: Login
    let coordinator: Coordinator

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(login.displayName)
                Text(rowStateText(timerState(
                    for: login, now: coordinator.now, leadTime: coordinator.model.state.settings.warningLeadTime)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Log in") { coordinator.logIn([login.id]) }
        }
    }
}
