import PrinceClockInCore
import SwiftUI

/// "Logged in now", or "Expires at" a time, for one login. Shown inline, never as a sheet, since a
/// sheet in the `.window` panel loses focus with the panel. `onSet` runs once a timer is set.
struct SetTimerControls: View {
    let login: Login
    let coordinator: Coordinator
    let onSet: () -> Void
    @State private var expiresAt: Date
    @State private var refusal: String?

    init(login: Login, coordinator: Coordinator, onSet: @escaping () -> Void) {
        self.login = login
        self.coordinator = coordinator
        self.onSet = onSet
        _expiresAt = State(initialValue: expiry(of: login) ?? coordinator.now.addingTimeInterval(3600))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Logged in now") {
                    coordinator.markLoggedInNow(id: login.id)
                    onSet()
                }
                Spacer()
                DatePicker("Expires at", selection: $expiresAt, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.field)
                Button("Set") { setExpiry() }
            }
            if let refusal {
                Text(refusal)
                    .foregroundStyle(.red)
            }
        }
        .font(.callout)
    }

    private func setExpiry() {
        do {
            try coordinator.setExpiry(id: login.id, expiresAt: expiresAt)
            refusal = nil
            onSet()
        } catch {
            refusal = "That time has already passed."
        }
    }
}

/// A login's session length in hours, saved when the field is submitted. Empty means unknown.
struct SessionLengthField: View {
    private static let secondsPerHour: Double = 3600

    let login: Login
    let coordinator: Coordinator

    var body: some View {
        LabeledContent("Session length") {
            HStack(spacing: 4) {
                TextField("Unknown", value: hours, format: .number)
                    .frame(width: 70)
                Text("hours")
            }
        }
        .font(.callout)
    }

    private var hours: Binding<Double?> {
        Binding(
            get: { login.sessionLength.map { $0 / Self.secondsPerHour } },
            set: { hours in
                let length = hours.flatMap { $0 > 0 ? $0 * Self.secondsPerHour : nil }
                coordinator.setSessionLength(id: login.id, to: length)
            })
    }
}
