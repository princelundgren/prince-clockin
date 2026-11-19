import PrinceClockInCore
import SwiftUI

/// One login's tile in the panel. Its first line is a menu of the login's actions, or, for a due
/// login, a button that logs in beside a "…" menu; below it is whatever the login needs answered.
/// The core decides everything shown; the tile draws it and forwards the user's choices. Its own
/// state, and its Set Timer's in the panel session, lasts one opening of the panel.
struct TileView: View {
    let login: Login
    let tile: TilePresentation
    let coordinator: Coordinator
    let session: PanelSession
    let prominent: ProminentAction?
    /// The control the tile was when the pointer entered it, so a click's action can't change
    /// under the pointer. The panel keeps it, since it builds the tile from it.
    @Binding var heldControl: TileControl?
    let openSettingsOnLogins: () -> Void
    @State private var showsSessionLengthField = false
    @State private var output: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            control(tile)
                .onHover { isInside in heldControl = isInside ? tile.control : nil }
            if let detail = tile.detail {
                detailView(detail, tile: tile)
            }
            if session.openSetTimer == login.id {
                setTimerForm
                    .foregroundStyle(secondaryText(tile))
            }
            if showsSessionLengthField {
                SessionLengthField(login: login, coordinator: coordinator)
            }
        }
        .padding(8)
        .background(tint(tile), in: RoundedRectangle(cornerRadius: 8))
        .contextMenu { actionItems(tile) }
        .onChange(of: tile.detail) { output = nil }
    }

    // MARK: First line

    @ViewBuilder private func control(_ tile: TilePresentation) -> some View {
        switch tile.control {
        case .actionsMenu:
            Menu {
                actionItems(tile)
            } label: {
                firstLine(tile, showsEllipsis: true)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(TileButtonStyle())
            .accessibilityLabel(tile.accessibilityLabel)
            .accessibilityHint(tile.accessibilityHint)
            .accessibilityActions { accessibilityActions(tile) }
        case .logInButton:
            HStack(spacing: 4) {
                Button {
                    if tile.clickLogsIn { perform(.logIn) }
                } label: {
                    firstLine(tile, showsEllipsis: false)
                }
                .buttonStyle(TileButtonStyle())
                .accessibilityLabel(tile.accessibilityLabel)
                .accessibilityHint(tile.accessibilityHint)
                .accessibilityActions { accessibilityActions(tile) }
                Menu {
                    actionItems(tile)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.borderless)
                .fixedSize()
                .accessibilityLabel(tile.actionsLabel)
            }
        }
    }

    private func firstLine(_ tile: TilePresentation, showsEllipsis: Bool) -> some View {
        HStack(spacing: 8) {
            symbol(tile)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(tile.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(tile.name)
                subtitle(tile.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(secondaryText(tile))
            }
            Spacer(minLength: 4)
            trailing(tile)
                .fixedSize()
                .layoutPriority(1)
            if showsEllipsis {
                Image(systemName: "ellipsis")
                    .foregroundStyle(secondaryText(tile))
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private func symbol(_ tile: TilePresentation) -> some View {
        switch tile.symbol {
        case .systemImage(let name):
            Image(systemName: name)
                .imageScale(.large)
                .foregroundStyle(tile.colour.map { Color($0.rawValue) } ?? Color.secondary)
        case .progress:
            ProgressView()
                .controlSize(.small)
        }
    }

    /// A kind gives way, by truncating, before the name and trailing text; a status never does.
    @ViewBuilder private func subtitle(_ subtitle: TileSubtitle) -> some View {
        switch subtitle {
        case .kind(let text):
            Text(text)
                .lineLimit(1)
        case .status(let text):
            Text(text)
                .lineLimit(1)
                .fixedSize()
        }
    }

    @ViewBuilder private func trailing(_ tile: TilePresentation) -> some View {
        switch tile.trailing {
        case .timeLeft(let text):
            Text(text)
                .monospacedDigit()
        case .stateWord(let word):
            Text(word)
        case .logIn:
            LogInLabel(isProminent: prominent == .logIn(id: tile.id))
        }
    }

    // MARK: Below the first line

    @ViewBuilder private func detailView(_ detail: TileDetail, tile: TilePresentation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch detail {
            case .failed(let message):
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Try Again") { perform(.logIn) }
                        .prominent(prominent == .tryAgain(id: tile.id))
                    if output == nil {
                        Button("Show Output…") {
                            Task { output = await coordinator.output(for: login.id) ?? "No output." }
                        }
                    } else {
                        Button("Hide Output") { output = nil }
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
            case .possibleLogin(let question, let confirmTitle):
                Text(question)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(confirmTitle) { coordinator.confirmPossibleLogin(id: login.id) }
                        .prominent(prominent == .markAsLoggedInAt(id: tile.id))
                    Button("Set Timer…") { openSetTimer() }
                }
            case .stillValid(let message):
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Edit Session Length…") { showsSessionLengthField = true }
            case .notYetApproved(let command):
                Text("This command hasn't run on this Mac yet:")
                Text(command)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Run It") { coordinator.approveAndLogIn(login.id) }
                    Button("Not Now") { coordinator.dismissPendingApproval(id: login.id) }
                }
            }
        }
        .font(.callout)
        .foregroundStyle(secondaryText(tile))
        .buttonStyle(.bordered)
    }

    private var setTimerForm: some View {
        let draft = Binding(
            get: { session.setTimerDrafts[login.id] ?? newSetTimerDraft() },
            set: { session.setTimerDrafts[login.id] = $0 })
        return SetTimerForm(
            id: login.id, draft: draft, coordinator: coordinator, note: PanelSession.setTimerNote, cancelTitle: "Cancel",
            onCancel: { session.closeSetTimer(for: login.id) }, onSet: { session.closeSetTimer(for: login.id) })
    }

    // MARK: Actions

    /// The "…" menu, which is also the tile's context menu.
    @ViewBuilder private func actionItems(_ tile: TilePresentation) -> some View {
        ForEach(tile.menuItems, id: \.self) { item in
            switch item {
            case .sessionLength:
                Menu(item.title) {
                    ForEach(sessionLengthOptions(current: login.sessionLength), id: \.self) { option in
                        Toggle(option.title, isOn: Binding(
                            get: { option.isSelected },
                            set: { _ in choose(option.choice) }))
                    }
                }
            case .cancelAll:
                Divider()
                Button(item.title) { perform(item) }
            case .logIn, .setTimer, .markLoggedInNow, .editInSettings:
                Button(item.title) { perform(item) }
            }
        }
    }

    /// The menu's items as VoiceOver actions, the Session Length submenu as one action per length.
    @ViewBuilder private func accessibilityActions(_ tile: TilePresentation) -> some View {
        ForEach(tile.menuItems, id: \.self) { item in
            if item == .sessionLength {
                ForEach(sessionLengthOptions(current: login.sessionLength), id: \.self) { option in
                    Button("\(item.title): \(option.title)") { choose(option.choice) }
                }
            } else {
                Button(item.title) { perform(item) }
            }
        }
    }

    /// The held control stays held, so acting on the tile can't change what the next click does.
    private func perform(_ item: TileMenuItem) {
        switch item {
        case .logIn: coordinator.logIn([login.id])
        case .setTimer: openSetTimer()
        case .markLoggedInNow(opensSetTimer: true):
            session.openSetTimerMarkingLoggedInNow(for: login.id, now: coordinator.now, newDraft: newSetTimerDraft)
        case .markLoggedInNow(opensSetTimer: false): coordinator.markLoggedInNow(id: login.id)
        case .sessionLength: break
        case .editInSettings: openSettingsOnLogins()
        case .cancelAll: coordinator.cancelBatch()
        }
    }

    private func choose(_ choice: SessionLengthChoice) {
        switch choice {
        // Only listed lengths, which the core accepts; any other length shows as Custom….
        case .length(let length): try? coordinator.setSessionLength(id: login.id, to: length)
        case .custom: showsSessionLengthField = true
        case .noTimer: try? coordinator.setSessionLength(id: login.id, to: nil)
        }
    }

    private func openSetTimer() {
        session.openSetTimer(for: login.id, newDraft: newSetTimerDraft)
    }

    private func newSetTimerDraft() -> SetTimerDraft {
        SetTimerDraft(for: login, now: coordinator.now, locale: .current)
    }

    // MARK: Colour

    /// A 10% tint of the state's colour token, or the system's quietest fill for a state no token
    /// means.
    private func tint(_ tile: TilePresentation) -> AnyShapeStyle {
        guard let colour = tile.colour else { return AnyShapeStyle(.quinary) }
        return AnyShapeStyle(Color(colour.rawValue).opacity(0.1))
    }

    /// `.secondary` falls to about 3.7:1 on a light-appearance tint, so text there is `.primary`.
    private func secondaryText(_ tile: TilePresentation) -> Color {
        colorScheme == .light && tile.colour != nil ? .primary : .secondary
    }
}

/// A tile's first line as a control: the label alone, dimmed while pressed.
private struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// The visible Log In on a due tile, which the whole tile's button performs. Prominent, it takes
/// the Accent fill under white text.
private struct LogInLabel: View {
    let isProminent: Bool

    var body: some View {
        Text("Log In")
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .foregroundStyle(isProminent ? Color.white : Color.primary)
            .background(
                isProminent ? AnyShapeStyle(Color("Accent")) : AnyShapeStyle(.quaternary),
                in: RoundedRectangle(cornerRadius: 6))
    }
}

extension View {
    /// The panel's one prominent button, on the Accent fill, or a bordered one.
    @ViewBuilder func prominent(_ isProminent: Bool) -> some View {
        if isProminent {
            buttonStyle(.borderedProminent).tint(Color("Accent"))
        } else {
            buttonStyle(.bordered)
        }
    }
}
