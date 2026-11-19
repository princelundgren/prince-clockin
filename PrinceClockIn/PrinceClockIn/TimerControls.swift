import PrinceClockInCore
import SwiftUI

/// Set Timer for one login: Mark as Logged In Now, or Expires In or Logged In At with a session
/// length. Shown inline, never as a sheet, since a sheet in the `.window` panel loses focus with
/// the panel. `onSet` runs once a timer is set.
struct SetTimerControls: View {
    private enum Mode: Hashable {
        case expiresIn, loggedInAt
    }

    private static let secondsPerHour: Double = 3600

    let login: Login
    let coordinator: Coordinator
    let onSet: () -> Void
    @State private var mode = Mode.expiresIn
    @State private var expiresInHours: Double? = 1
    @State private var loggedInAt: Date
    @State private var sessionLengthHours: Double?
    @State private var refusal: String?

    init(login: Login, coordinator: Coordinator, onSet: @escaping () -> Void) {
        self.login = login
        self.coordinator = coordinator
        self.onSet = onSet
        _loggedInAt = State(initialValue: login.loginTime ?? coordinator.now)
        _sessionLengthHours = State(initialValue: login.sessionLength.map { $0 / Self.secondsPerHour })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("Mark as Logged In Now") {
                coordinator.markLoggedInNow(id: login.id)
                onSet()
            }
            Picker("Set Timer", selection: $mode) {
                Text("Expires In").tag(Mode.expiresIn)
                Text("Logged In At").tag(Mode.loggedInAt)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch mode {
            case .expiresIn:
                HoursField(label: "Expires in", hours: $expiresInHours)
            case .loggedInAt:
                DatePicker("Logged in at", selection: $loggedInAt, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.field)
            }
            HoursField(label: "Session length", hours: $sessionLengthHours)
            HStack {
                if let refusal {
                    Text(refusal)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Set") { setTimer() }
                    .disabled(sessionLengthHours == nil || (mode == .expiresIn && expiresInHours == nil))
            }
        }
        .font(.callout)
    }

    private func setTimer() {
        guard let sessionLengthHours else { return }
        let sessionLength = sessionLengthHours * Self.secondsPerHour
        do throws(TimerError) {
            switch mode {
            case .expiresIn:
                guard let expiresInHours else { return }
                try coordinator.setTimer(
                    id: login.id, .expiresIn(expiresInHours * Self.secondsPerHour, sessionLength: sessionLength))
            case .loggedInAt:
                try coordinator.setTimer(id: login.id, .loggedInAt(loggedInAt, sessionLength: sessionLength))
            }
            refusal = nil
            onSet()
        } catch {
            refusal = error.message
        }
    }
}

/// A number of hours, typed.
private struct HoursField: View {
    let label: String
    @Binding var hours: Double?

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                TextField("Hours", value: $hours, format: .number)
                    .frame(width: 70)
                Text("hours")
            }
        }
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
