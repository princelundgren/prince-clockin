import PrinceClockInCore
import SwiftUI

/// The menu bar panel: banners, the running batch, one tile per login, the log-in actions and the
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
            ForEach(appModel.panelBanners, id: \.self) { banner in
                BannerView(banner: banner) { perform($0, on: banner) }
            }
            if let card = coordinator.batchCard {
                BatchCardView(card: card, coordinator: coordinator)
            }
            if logins.isEmpty, let empty = session.emptyPanel {
                EmptyPanelView(empty: empty, addLogins: openSettingsOnLogins)
            }
            tileList(tiles, prominent: prominent)
            if showsLogInToDue {
                Button("Log In to \(dueCount) Due") {
                    coordinator.logIn(coordinator.model.dueLogins(now: coordinator.now).map(\.id))
                }
                .prominent(prominent == .logInToDue)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if !logins.isEmpty, !coordinator.model.state.presets.isEmpty {
                Divider()
                presets
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
            if !logins.isEmpty {
                Divider()
                checkDatabricksNow
            }
            Divider()
            footer
        }
        .padding()
        .frame(width: 320)
        .onChange(of: appModel.panelBanners) { _, banners in session.show(banners) }
        .task(id: EmptyPanelTrigger(opening: session.openings, hasNoLogins: logins.isEmpty)) {
            await discoverForEmptyPanel()
        }
    }

    /// With no login tracked, what discovery finds in the config files, read again for each
    /// opening and whenever the last login goes.
    private func discoverForEmptyPanel() async {
        guard logins.isEmpty else { return }
        let opening = session.openings
        let found = await coordinator.discoverCandidates()
        guard !Task.isCancelled else { return }
        session.showEmptyPanel(
            emptyPanel(aws: found.aws, databricks: found.databricks, locale: .current), forOpening: opening)
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

    private func perform(_ action: BannerAction, on banner: Banner) {
        switch action {
        case .showInFinder:
            if case .stateSetAside(let backup) = banner { NSWorkspace.shared.activateFileViewerSelecting([backup]) }
        case .dismiss: coordinator.dismissLoadNotice()
        case .tryAgain: coordinator.retrySave()
        case .openNotificationSettings: NSWorkspace.shared.open(AppLinks.notificationSettings)
        }
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Presets")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            FlowButtons(buttons: presetButtons) { id in
                guard let preset = coordinator.model.state.presets.first(where: { $0.id == id }) else { return }
                coordinator.logIn(coordinator.model.logins(in: preset).map(\.id))
            }
        }
    }

    /// Here until Settings → Logins has Check Databricks Now.
    private var checkDatabricksNow: some View {
        Button("Check Databricks Now") {
            Task { await coordinator.checkNow() }
        }
        .disabled(!coordinator.canCheckDatabricksNow)
        .help("Ask the Databricks CLI whether each Databricks login is still valid")
    }

    private var presetButtons: [PresetButton] {
        coordinator.model.state.presets.map { preset in
            presetButton(for: preset, logins: coordinator.model.logins(in: preset), locale: .current)
        }
    }

    private var footer: some View {
        HStack {
            Button("Settings…", systemImage: "gearshape", action: openSettings)
                .labelStyle(.iconOnly)
                .help("Settings…")
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}

/// What the panel keeps for one opening: its tiles' order, taken as it opens, what discovery found
/// while no login is tracked, the control each tile held when the pointer entered it, and whether
/// the Notifications off banner was on screen. Closing the panel clears it and counts the closing,
/// which gives the tiles new state for the next opening.
@MainActor
@Observable
final class PanelSession {
    private(set) var order: [UUID] = []
    private(set) var emptyPanel: EmptyPanel?
    var heldControls: [UUID: TileControl] = [:]
    private(set) var openings = 0
    private(set) var closings = 0
    @ObservationIgnored private var notificationsBanner = NotificationsBannerSighting()

    func open(order: [UUID]) {
        self.order = order
        openings += 1
        notificationsBanner.panelOpened()
    }

    /// Discovery's answer for the empty panel, which arrives after the panel opens; one for an
    /// earlier opening, or arriving after the panel closed, is dropped.
    func showEmptyPanel(_ emptyPanel: EmptyPanel, forOpening opening: Int) {
        guard opening == openings, closings < openings else { return }
        self.emptyPanel = emptyPanel
    }

    /// This opening read the notification permission, and the panel shows `banners`.
    func permissionRefreshed(showing banners: [Banner]) {
        notificationsBanner.permissionRefreshed(showing: banners)
    }

    /// The panel's banners changed to `banners`.
    func show(_ banners: [Banner]) {
        notificationsBanner.panelShows(banners)
    }

    /// Returns whether the Notifications off banner was on screen during this opening, once its
    /// permission was read.
    func close() -> Bool {
        heldControls = [:]
        emptyPanel = nil
        closings += 1
        return notificationsBanner.panelClosed()
    }
}

/// When the panel discovers logins for its empty state: once per opening, and again when the last
/// login goes while it is open.
private struct EmptyPanelTrigger: Equatable {
    let opening: Int
    let hasNoLogins: Bool
}

/// No login tracked: what discovery found, and Add Logins….
private struct EmptyPanelView: View {
    let empty: EmptyPanel
    let addLogins: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = empty.title {
                Text(title)
                    .font(.headline)
            }
            Text(empty.message)
                .fixedSize(horizontal: false, vertical: true)
            Button("Add Logins…", action: addLogins)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

private struct BannerView: View {
    let banner: Banner
    let perform: (BannerAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(banner.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            HStack {
                Spacer()
                ForEach(banner.actions, id: \.self) { action in
                    Button(action.title) { perform(action) }
                }
            }
        }
        .font(.callout)
    }
}

/// One button per preset, in a row if they fit, else one per line; a name too long for the panel
/// is truncated at the end, and its note after it never is.
private struct FlowButtons: View {
    let buttons: [PresetButton]
    let action: (UUID) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack { buttonViews }
            VStack(alignment: .leading) { buttonViews }
        }
    }

    private var buttonViews: some View {
        ForEach(buttons) { button in
            Button { action(button.id) } label: {
                HStack(spacing: 0) {
                    Text(button.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let note = button.note {
                        Text(" · \(note)")
                            .fixedSize()
                    }
                }
            }
            .disabled(!button.isEnabled)
            .help(button.helpTag)
        }
    }
}

/// The running batch: which login runs and what to do, or the custom login waiting for Done.
private struct BatchCardView: View {
    let card: BatchCard
    let coordinator: Coordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch card {
            case .running(let title, let progress, let instruction, let failures):
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(progress)
                        .monospacedDigit()
                        .fixedSize()
                }
                if let failures {
                    Text(failures)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                if let instruction {
                    Text(instruction)
                        .fixedSize(horizontal: false, vertical: true)
                }
                buttons(done: nil)
            case .waitingForDone(let id, let title, let instruction):
                Text(title)
                    .font(.headline)
                Text(instruction)
                    .fixedSize(horizontal: false, vertical: true)
                buttons(done: id)
            }
        }
        .font(.callout)
    }

    /// Cancel All, and Done for custom login `done` when it waits.
    private func buttons(done: UUID?) -> some View {
        HStack {
            Spacer()
            Button("Cancel All") { coordinator.cancelBatch() }
            if let done {
                Button("Done") { coordinator.confirmCustomDone(id: done) }
            }
        }
        .buttonStyle(.bordered)
    }
}
