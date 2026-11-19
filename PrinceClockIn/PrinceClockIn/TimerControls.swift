import PrinceClockInCore
import SwiftUI

/// Set Timer for one login: Expires In or Logged In At, a Session Length pop-up, a caption that
/// says when the login would expire or why Set refuses, then `cancelTitle` and Set. Shown inline, never as
/// a sheet, since a sheet in the popover loses focus with it. The draft belongs to the caller, so
/// it outlives the form's redraws; `note`, when given, is a line on how long it is kept.
struct SetTimerForm: View {
    let id: UUID
    @Binding var draft: SetTimerDraft
    let coordinator: Coordinator
    let note: String?
    let cancelTitle: String
    let isSetProminent: Bool
    let onCancel: () -> Void
    let onSet: () -> Void
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
                    Text("hours")
                    NumberField(label: "Minutes", text: $draft.minutes)
                        .padding(.leading, 4)
                    Text("minutes")
                }
            case .loggedInAt:
                DatePicker("Logged in at", selection: $draft.loggedInAt, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.field)
                    .labelsHidden()
            }
            Picker("Session length", selection: $draft.sessionLength) {
                ForEach(sessionLengthOptions(current: nil), id: \.choice) { option in
                    Text(option.title).tag(option.choice)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            if draft.sessionLength == .custom {
                HStack(spacing: 4) {
                    NumberField(label: "Session length in hours", text: $draft.customHours)
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
                Button(cancelTitle, action: onCancel)
                Button("Set") { set() }
                    .prominent(isSetProminent)
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
            onSet()
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

/// A short field for a number typed as text, which the core parses.
private struct NumberField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        TextField(label, text: $text)
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 44)
    }
}

/// A login's session length in hours, saved when the field is submitted. Empty means unknown; a
/// length over the cap isn't saved, and the field says why.
struct SessionLengthField: View {
    private static let secondsPerHour: Double = 3600

    let login: Login
    let coordinator: Coordinator
    @State private var refusal: TimerError?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent("Session length") {
                HStack(spacing: 4) {
                    TextField("Unknown", value: hours, format: .number)
                        .frame(width: 70)
                    Text("hours")
                }
            }
            if let refusal {
                Text(refusal.message)
            }
        }
        .font(.callout)
    }

    private var hours: Binding<Double?> {
        Binding(
            get: { login.sessionLength.map { $0 / Self.secondsPerHour } },
            set: { hours in
                let length = hours.flatMap { $0 > 0 ? $0 * Self.secondsPerHour : nil }
                do throws(TimerError) {
                    try coordinator.setSessionLength(id: login.id, to: length)
                    refusal = nil
                } catch {
                    refusal = error
                }
            })
    }
}
