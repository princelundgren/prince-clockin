import PrinceClockInCore
import SwiftUI

/// Set Timer for one login: Expires In or Logged In At, a Session Length pop-up, a caption that
/// says when the login would expire or why Set refuses, then `cancelTitle` and Set. Shown inline,
/// never as a sheet, since a sheet in the popover loses focus with it. The draft belongs to the
/// caller, so it outlives the form's redraws; `note`, when given, is a line on how long it is
/// kept. `onClose` runs after Cancel or Set.
struct SetTimerForm: View {
    let id: UUID
    @Binding var draft: SetTimerDraft
    let coordinator: Coordinator
    let note: String?
    let cancelTitle: String
    let defaults: PanelDefaults
    let focus: FocusState<PanelFocus?>.Binding
    let onClose: () -> Void
    /// What Set was refused with, when the clock moved past what the caption checked.
    @State private var refusal: TimerError?

    var body: some View {
        let check = draft.check(now: coordinator.now, locale: .current)
        VStack(alignment: .leading, spacing: 6) {
            Picker("Set Timer", selection: $draft.mode) {
                Text("Expires In").tag(SetTimerMode.expiresIn)
                Text("Logged In At").tag(SetTimerMode.loggedInAt)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch draft.mode {
            case .expiresIn:
                HStack(spacing: 4) {
                    NumberField(label: "Hours", text: $draft.hours)
                        .focused(focus, equals: .textField(id, .hours))
                    Text("hours")
                    NumberField(label: "Minutes", text: $draft.minutes)
                        .focused(focus, equals: .textField(id, .minutes))
                        .padding(.leading, 4)
                    Text("minutes")
                }
            case .loggedInAt:
                DatePicker("Logged in at", selection: $draft.loggedInAt, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.field)
                    .labelsHidden()
                    .focused(focus, equals: .textField(id, .loggedInAt))
            }
            SessionLengthPopUp(selection: $draft.sessionLength)
                .fixedSize()
            if draft.sessionLength == .custom {
                HStack(spacing: 4) {
                    NumberField(label: "Session length in hours", text: $draft.customHours, prompt: "Hours")
                        .focused(focus, equals: .textField(id, .customHours))
                    Text("hours")
                }
            }
            if let caption = refusal?.message
                ?? setTimerCaption(for: check, now: coordinator.now, locale: .current, calendar: .current) {
                Text(caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note {
                Text(note)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(cancelTitle, action: onClose)
                    .escapeKey(defaults.cancelledByEscape == id)
                Button("Set") { set() }
                    .prominent(defaults.prominent == .set(id: id))
                    .returnKey(defaults.onReturn == .set(id: id))
                    .disabled(!check.isReady)
            }
            .buttonStyle(.bordered)
        }
        .font(.callout)
        .onChange(of: draft) { refusal = nil }
    }

    private func set() {
        guard let entry = draft.entry(locale: .current) else { return }
        do throws(TimerError) {
            try coordinator.setTimer(id: id, entry)
            onClose()
        } catch {
            refusal = error
        }
    }
}

private extension SetTimerCheck {
    var isReady: Bool {
        if case .ready = self { true } else { false }
    }
}

/// The one list of session lengths as a pop-up, for Set Timer and Settings: 8 hours to 7 days,
/// Custom… and No timer.
struct SessionLengthPopUp: View {
    @Binding var selection: SessionLengthChoice

    var body: some View {
        Picker("Session length", selection: $selection) {
            ForEach(sessionLengthOptions(), id: \.choice) { option in
                Text(option.title).tag(option.choice)
            }
        }
        .pickerStyle(.menu)
    }
}

/// A short field for a number typed as text, which the core parses; `prompt`, when given, is its
/// empty placeholder.
struct NumberField: View {
    let label: String
    @Binding var text: String
    var prompt: String?

    var body: some View {
        TextField(label, text: $text, prompt: prompt.map { Text($0) })
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 44)
    }
}

/// A login's session length in hours. The text is a draft its caller keeps, stored on Return or
/// when focus leaves the field, never while typing, since `TextField(value:format:)` writes its
/// value as the user types. Empty text makes the length unknown; text the core refuses stays, with
/// the refusal under it, and nothing is stored.
struct SessionLengthField: View {
    let login: Login
    let coordinator: Coordinator
    let focus: FocusState<PanelFocus?>.Binding
    /// What was typed since the last store, or `nil` to show the stored length.
    @Binding var draft: SessionLengthFieldDraft?
    /// The field's label, which Settings' Custom… row names apart from the pop-up beside it.
    var title = "Session length"

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(title) {
                HStack(spacing: 4) {
                    TextField("Session length in hours", text: text, prompt: Text("Hours"))
                        .labelsHidden()
                        .focused(focus, equals: fieldFocus)
                        .onSubmit(store)
                        .frame(width: 70)
                    Text("hours")
                }
            }
            if let refusal = draft?.refusal {
                Text(refusal.message)
            }
        }
        .font(.callout)
        .onChange(of: focus.wrappedValue) { old, new in
            if old == fieldFocus, new != fieldFocus { store() }
        }
    }

    private var fieldFocus: PanelFocus { .textField(login.id, .sessionLength) }

    private var text: Binding<String> {
        Binding(
            get: { draft?.text ?? sessionLengthHoursText(login.sessionLength, locale: .current) },
            set: { draft = SessionLengthFieldDraft(text: $0) })
    }

    private func store() {
        guard let text = draft?.text else { return }
        do throws(SessionLengthRefusal) {
            try coordinator.setSessionLength(id: login.id, fieldText: text, locale: .current)
            draft = nil
        } catch {
            draft?.refusal = error
        }
    }
}

/// The session length field's text while it differs from the stored length, and why storing it
/// was refused, kept outside the field so a redrawn tile doesn't lose it.
struct SessionLengthFieldDraft {
    let text: String
    var refusal: SessionLengthRefusal?
}
