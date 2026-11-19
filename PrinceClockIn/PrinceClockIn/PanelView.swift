import PrinceClockInCore
import SwiftUI

/// The menu bar panel: notices, the running batch, one tile per login, the log-in actions and the
/// footer.
struct PanelView: View {
    /// Past this height the tiles scroll.
    private static let tilesMaximumHeight: CGFloat = 420

    let appModel: AppModel
    let updater: Updater
    let session: PanelSession
    let openSettings: () -> Void
    let openSettingsOnLogins: () -> Void

    private var coordinator: Coordinator { appModel.coordinator }
    private var logins: [Login] { coordinator.model.state.logins }
    /// Each login's tile, in the order the panel took when it opened, built with the control
    /// each tile holds.
    private var tilePresentations: [(login: Login, tile: TilePresentation)] {
        coordinator.model.logins(inOrder: session.order).compactMap { login in
            coordinator.tile(
                for: login.id, holding: session.heldControls[login.id], locale: .current, calendar: .current
            ).map { (login, $0) }
        }
    }
    private var dueCount: Int { coordinator.model.dueLogins(now: coordinator.now).count }
    private var showsLogInToDue: Bool {
        PrinceClockInCore.showsLogInToDue(dueCount: dueCount, isBatchRunning: coordinator.batch != nil)
    }

    var body: some View {
        let tiles = tilePresentations
        let prominent = prominentAction(
            tiles: tiles.map(\.tile), showsLogInToDue: showsLogInToDue, isBatchRunning: coordinator.batch != nil)
        VStack(alignment: .leading, spacing: 10) {
            notices
            if let batch = coordinator.batch {
                BatchSection(batch: batch, coordinator: coordinator)
            }
            if logins.isEmpty {
                Text("No logins tracked yet. Add them in Settings.")
                    .foregroundStyle(.secondary)
            }
            tileList(tiles, prominent: prominent)
            if showsLogInToDue {
                Button("Log In to \(dueCount) Due") {
                    coordinator.logIn(coordinator.model.dueLogins(now: coordinator.now).map(\.id))
                }
                .prominent(prominent == .logInToDue)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if !logins.isEmpty {
                Divider()
                actions
            }
            if let line = updater.status.line {
                Divider()
                HStack {
                    Text(line.text)
                    Spacer()
                    if line.showsView {
                        Button("View…") { updater.checkForUpdates() }
                    }
                }
            }
            Divider()
            footer
        }
        .padding()
        .frame(width: 320)
    }

    /// The tiles, new for each opening of the panel, so a form or output left open doesn't come back.
    private func tileList(_ tiles: [(login: Login, tile: TilePresentation)], prominent: ProminentAction?) -> some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(tiles, id: \.tile.id) { entry in
                    TileView(
                        login: entry.login, tile: entry.tile, coordinator: coordinator, prominent: prominent,
                        heldControl: heldControl(for: entry.login.id), openSettingsOnLogins: openSettingsOnLogins)
                }
            }
        }
        .id(session.closings)
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: Self.tilesMaximumHeight)
    }

    private func heldControl(for id: UUID) -> Binding<TileControl?> {
        Binding(get: { session.heldControls[id] }, set: { session.heldControls[id] = $0 })
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
}

/// What the panel keeps for one opening: its tiles' order, taken as it opens, and the control each
/// tile held when the pointer entered it. Closing the panel clears it and counts the closing, which
/// gives the tiles new state for the next opening.
@MainActor
@Observable
final class PanelSession {
    private(set) var order: [UUID] = []
    var heldControls: [UUID: TileControl] = [:]
    private(set) var closings = 0

    func open(order: [UUID]) {
        self.order = order
    }

    func close() {
        heldControls = [:]
        closings += 1
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
