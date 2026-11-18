import PrinceClockInCore
import SwiftUI

/// One login in the panel: its checkbox, name and state, "Log in" and "Set timer", and whatever
/// the login needs answered: a possible login to confirm, a Databricks mismatch, the last failure.
struct LoginRow: View {
    private enum Expanded {
        case setTimer, sessionLength
    }

    let login: Login
    let coordinator: Coordinator
    @Binding var isSelected: Bool
    @State private var expanded: Expanded?
    @State private var output: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(login.displayName, isOn: $isSelected)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                VStack(alignment: .leading) {
                    Text(login.displayName)
                    Text(rowStateText(timerState(
                        for: login, now: coordinator.now, leadTime: coordinator.model.state.settings.warningLeadTime)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Set timer") { toggle(.setTimer) }
                Button("Log in") { coordinator.logIn([login.id]) }
            }
            if let rewrite = coordinator.model.possibleLogins[login.id] {
                HStack {
                    Text("Logged in at \(rewrite.formatted(date: .omitted, time: .shortened))?")
                    Button("Yes") { coordinator.confirmPossibleLogin(id: login.id) }
                }
                .font(.callout)
            }
            if coordinator.model.validWhileExpired.contains(login.id) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Databricks says this login is still valid, but its timer has run out. Its session length may be too short.")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Edit session length") { toggle(.sessionLength) }
                }
                .font(.callout)
            }
            if let failure = coordinator.lastFailures[login.id] {
                failureView(failure)
            }
            switch expanded {
            case .setTimer:
                SetTimerControls(login: login, coordinator: coordinator) { expanded = nil }
            case .sessionLength:
                SessionLengthField(login: login, coordinator: coordinator)
            case nil:
                EmptyView()
            }
        }
        .onChange(of: coordinator.lastFailures[login.id]) { output = nil }
    }

    private func failureView(_ failure: LoginFailure) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(failure.message)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if output == nil {
                    Button("Show output") {
                        Task { output = await coordinator.output(for: login.id) ?? "No output." }
                    }
                } else {
                    Button("Hide output") { output = nil }
                }
            }
            if let output {
                ScrollView {
                    Text(output)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
        }
        .font(.callout)
    }

    private func toggle(_ section: Expanded) {
        expanded = expanded == section ? nil : section
    }
}
