import PrinceClockInCore
import SwiftUI

/// One login's tile in the panel. Its first line is a button that logs in while nothing is pending;
/// below it is whatever the login needs answered.
/// The core decides everything shown; the tile draws it and forwards the user's choices. Its own
/// state, and its Set Timer's in the panel session, lasts one opening of the panel.
struct TileView: View {
    let login: Login
    let tile: TilePresentation
    let coordinator: Coordinator
    let session: PanelSession
    let defaults: PanelDefaults
    let focus: FocusState<PanelFocus?>.Binding
    @State private var showsSessionLengthField = false
    @State private var output: String?
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            firstLineButton(tile)
                .onHover { isHovered = $0 }
            if let detail = tile.detail {
                detailView(detail, tile: tile)
            }
            if session.openSetTimer == login.id {
                setTimerForm
                    .foregroundStyle(secondaryText(tile))
            }
            if showsSessionLengthField {
                SessionLengthField(
                    login: login, coordinator: coordinator, focus: focus,
                    draft: Bindable(session).sessionLengthDrafts[login.id])
            }
        }
        .tileFrame(tileFill(colour: tile.colour, isHovered: isHovered && tile.clickLogsIn))
        .onChange(of: tile.detail) { output = nil }
    }

    // MARK: First line

    private func firstLineButton(_ tile: TilePresentation) -> some View {
        Button {
            if tile.clickLogsIn { logIn() }
        } label: {
            firstLine(tile)
        }
        .buttonStyle(TileButtonStyle())
        .returnKey(defaults.onReturn == .logIn(id: tile.id))
        .focused(focus, equals: .tile(tile.id))
        .accessibilityLabel(tile.accessibilityLabel)
        .accessibilityHint(tile.accessibilityHint)
    }

    private func firstLine(_ tile: TilePresentation) -> some View {
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
        switch isHovered ? tile.trailingOnHover : tile.trailing {
        case .timeLeft(let text):
            Text(text)
                .monospacedDigit()
        case .stateWord(let word):
            Text(word)
        case .empty:
            EmptyView()
        case .logIn:
            LogInLabel(isProminent: defaults.prominent == .logIn(id: tile.id))
        }
    }

    // MARK: Below the first line

    @ViewBuilder private func detailView(_ detail: TileDetail, tile: TilePresentation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch detail {
            case .failed(let message, let offersAutomationSettings):
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                if offersAutomationSettings {
                    Button("Open System Settings…") { NSWorkspace.shared.open(AppLinks.automationSettings) }
                }
                HStack {
                    Button("Try Again") { logIn() }
                        .prominent(defaults.prominent == .tryAgain(id: tile.id))
                        .returnKey(defaults.onReturn == .tryAgain(id: tile.id))
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
                        .prominent(defaults.prominent == .markAsLoggedInAt(id: tile.id))
                        .returnKey(defaults.onReturn == .markAsLoggedInAt(id: tile.id))
                    Button("Log In") { logIn() }
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
            case .needsSessionLength(let prompt):
                Text(prompt)
                SessionLengthPopUp(selection: Binding(
                    get: { showsSessionLengthField ? .custom : .noTimer },
                    set: { choose($0) }))
                    .fixedSize()
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
            id: login.id, draft: draft, coordinator: coordinator, note: PanelSession.setTimerNote,
            defaults: defaults, focus: focus, onClose: closeSetTimer)
    }

    /// After Cancel or Set, focus goes back to the tile.
    private func closeSetTimer() {
        session.closeSetTimer(for: login.id)
        focus.wrappedValue = .tile(login.id)
    }

    // MARK: Actions

    private func logIn() {
        coordinator.logIn([login.id])
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

    /// `.secondary` falls to about 3.7:1 on a light-appearance tint, so text there is `.primary`.
    private func secondaryText(_ tile: TilePresentation) -> Color {
        colorScheme == .light && tile.colour != nil ? .primary : .secondary
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
