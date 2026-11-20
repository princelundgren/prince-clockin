import PrinceClockInCore
import SwiftUI

/// The menu bar panel: banners, the running batch, one tile per login, the log-in actions and the
/// footer.
struct PanelView: View {
    /// Past this height the tiles scroll.
    private static let tilesMaximumHeight: CGFloat = 420
    /// Past this height the preset tiles scroll: about four and a half, so the cut one shows there
    /// are more.
    private static let presetsMaximumHeight: CGFloat = 230

    let appModel: AppModel
    let updater: Updater
    let session: PanelSession
    let openSettings: () -> Void
    /// Add Logins…: Settings on Logins, with its + menu open.
    let addLogins: () -> Void
    @FocusState private var focus: PanelFocus?

    private var coordinator: Coordinator { appModel.coordinator }
    private var logins: [Login] { coordinator.model.state.logins }
    /// Each login's tile, in the order the panel took when it opened.
    private var tilePresentations: [(login: Login, tile: TilePresentation)] {
        coordinator.model.logins(inOrder: session.order).compactMap { login in
            coordinator.tile(for: login.id, locale: .current, calendar: .current).map { (login, $0) }
        }
    }
    private var dueCount: Int { coordinator.model.dueLogins(now: coordinator.now).count }
    private var showsLogInToDue: Bool {
        PrinceClockInCore.showsLogInToDue(dueCount: dueCount, isBatchRunning: coordinator.batch != nil)
    }
    /// The custom login whose Done the batch card shows.
    private var waitingForDone: UUID? {
        if case .waitingForDone(let id, _, _) = coordinator.batchCard { id } else { nil }
    }

    var body: some View {
        let tiles = tilePresentations
        let prominent = prominentAction(
            openSetTimer: session.openSetTimer, waitingForDone: waitingForDone, tiles: tiles.map(\.tile),
            showsLogInToDue: showsLogInToDue, isBatchRunning: coordinator.batch != nil)
        let keys = PanelKeyContext(
            prominent: prominent, openSetTimer: session.openSetTimer, isEditingText: focus?.isTextField ?? false,
            tiles: tiles.map(\.tile.id), focusedTile: focus?.tile)
        let defaults = PanelDefaults(keys: keys)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(appModel.panelBanners, id: \.self) { banner in
                BannerView(banner: banner) { perform($0, on: banner) }
            }
            if let card = coordinator.batchCard {
                BatchCardView(card: card, coordinator: coordinator, defaults: defaults)
            }
            if logins.isEmpty, let empty = session.emptyPanel {
                EmptyPanelView(empty: empty, addLogins: addLogins)
            }
            tileList(tiles, defaults: defaults, keys: keys)
            if showsLogInToDue {
                Button("Log In to \(dueCount) Due") {
                    coordinator.logIn(coordinator.model.dueLogins(now: coordinator.now).map(\.id))
                }
                .prominent(defaults.prominent == .logInToDue)
                .returnKey(defaults.onReturn == .logInToDue)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if !logins.isEmpty, !coordinator.model.state.presets.isEmpty {
                Divider()
                presets
                    .id(session.closings)
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
        .onChange(of: appModel.panelBanners) { _, banners in session.show(banners) }
        .onChange(of: session.showings) { focus = tiles.first.map { .tile($0.tile.id) } }
        .task(id: EmptyPanelTrigger(opening: session.openings, hasNoLogins: logins.isEmpty)) {
            await discoverForEmptyPanel()
        }
    }

    /// With no login tracked, what discovery finds in the config files, read again for each
    /// opening and whenever the last login goes.
    private func discoverForEmptyPanel() async {
        guard logins.isEmpty else { return }
        let opening = session.openings
        session.emptyPanelReadStarted()
        let found = await coordinator.discoverCandidates()
        guard !Task.isCancelled else { return }
        session.showEmptyPanel(
            emptyPanel(aws: found.aws, databricks: found.databricks, locale: .current), forOpening: opening)
    }

    /// The tiles, new for each opening of the panel, so a form or output left open doesn't come back.
    private func tileList(
        _ tiles: [(login: Login, tile: TilePresentation)], defaults: PanelDefaults, keys: PanelKeyContext
    ) -> some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(tiles, id: \.tile.id) { entry in
                    TileView(
                        login: entry.login, tile: entry.tile, coordinator: coordinator, session: session,
                        defaults: defaults, focus: $focus)
                }
            }
            .onMoveCommand { move($0, keys: keys) }
        }
        .id(session.closings)
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: Self.tilesMaximumHeight)
    }

    /// The up and down arrows move focus between the tiles.
    private func move(_ direction: MoveCommandDirection, keys: PanelKeyContext) {
        let key: PanelKey
        switch direction {
        case .up: key = .moveUp
        case .down: key = .moveDown
        default: return
        }
        if case .focusTile(let id) = panelKeyResponse(to: key, in: keys) { focus = .tile(id) }
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
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(presetTiles) { tile in
                        PresetTileView(tile: tile) { logIn(toPreset: tile.id) }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: Self.presetsMaximumHeight)
        }
    }

    private func logIn(toPreset id: UUID) {
        guard let preset = coordinator.model.state.presets.first(where: { $0.id == id }) else { return }
        coordinator.logIn(coordinator.model.logins(in: preset).map(\.id))
    }

    private var presetTiles: [PresetTile] {
        coordinator.model.state.presets.map { preset in
            presetTile(for: preset, logins: coordinator.model.logins(in: preset), locale: .current)
        }
    }

    private var footer: some View {
        HStack {
            FooterIconButton(title: "Settings…", systemImage: "gear", action: openSettings)
            Spacer()
            FooterIconButton(title: "Quit PrinceClockIn", systemImage: "power") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

/// A footer button: a plain secondary symbol whose whole 30 pt square takes the click, with its
/// title as the VoiceOver label and help tag.
private struct FooterIconButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .accessibilityLabel(title)
        .help(title)
    }
}

/// What the panel keeps for one opening: its tiles' order, taken as it opens, what discovery found
/// while no login is tracked, the open Set Timer and its drafts, and whether the Notifications off
/// banner was on screen. Closing the panel clears it and counts the closing, which gives the tiles
/// new state for the next opening; each showing is counted too, for the focus it starts with.
@MainActor
@Observable
final class PanelSession {
    /// The line in Set Timer that says how long its draft is kept.
    static let setTimerNote = "This form is kept until the panel closes."

    private(set) var order: [UUID] = []
    private(set) var emptyPanel: EmptyPanel?
    /// The login whose Set Timer is open; one at a time.
    private(set) var openSetTimer: UUID?
    /// Each login's Set Timer draft. Opening another login's form keeps this one's draft, so a
    /// click elsewhere in the panel loses nothing; only Cancel, Set and closing the panel discard it.
    var setTimerDrafts: [UUID: SetTimerDraft] = [:]
    /// Each login's session length field text while it is edited, until the panel closes.
    var sessionLengthDrafts: [UUID: SessionLengthFieldDraft] = [:]
    private(set) var openings = 0
    private(set) var showings = 0
    private(set) var closings = 0
    @ObservationIgnored private var notificationsBanner = NotificationsBannerSighting()

    func open(order: [UUID]) {
        self.order = order
        openings += 1
        notificationsBanner.panelOpened()
    }

    /// The panel is on screen and its window key.
    func didShow() {
        showings += 1
    }

    /// A new discovery read for the empty panel started, so no earlier answer shows while it runs.
    func emptyPanelReadStarted() {
        emptyPanel = nil
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

    /// Opens Set Timer on login `id`, with its draft from earlier in this opening, else `newDraft`.
    func openSetTimer(for id: UUID, newDraft: () -> SetTimerDraft) {
        if setTimerDrafts[id] == nil { setTimerDrafts[id] = newDraft() }
        openSetTimer = id
    }

    /// Cancel or Set on login `id`'s Set Timer: closes it and discards its draft.
    func closeSetTimer(for id: UUID) {
        setTimerDrafts[id] = nil
        if openSetTimer == id { openSetTimer = nil }
    }

    /// Returns whether the Notifications off banner was on screen during this opening, once its
    /// permission was read.
    func close() -> Bool {
        openSetTimer = nil
        setTimerDrafts = [:]
        sessionLengthDrafts = [:]
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

/// A preset's tile, drawn as a login tile is: one button over the whole tile, its logins under its
/// name, and Log In under the pointer. An empty preset's tile is dimmed and takes no click. Its
/// help tag is also its VoiceOver hint.
private struct PresetTileView: View {
    let tile: PresetTile
    let logIn: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: logIn) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.stack")
                    .imageScale(.large)
                    .foregroundStyle(Color.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tile.title)
                    Text(tile.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .truncationMode(.tail)
                Spacer(minLength: 4)
                if isHovered {
                    LogInLabel(isProminent: false)
                        .fixedSize()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(TileButtonStyle())
        .disabled(!tile.isEnabled)
        .onHover { isHovered = $0 && tile.isEnabled }
        .tileFrame(tileFill(colour: nil, isHovered: isHovered))
        .help(tile.helpTag)
        .accessibilityLabel(tile.accessibilityLabel)
    }
}

/// The running batch: which login runs and what to do, or the custom login waiting for Done.
private struct BatchCardView: View {
    let card: BatchCard
    let coordinator: Coordinator
    let defaults: PanelDefaults

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
                    .prominent(defaults.prominent == .done(id: done))
                    .returnKey(defaults.onReturn == .done(id: done))
            }
        }
        .buttonStyle(.bordered)
    }
}
