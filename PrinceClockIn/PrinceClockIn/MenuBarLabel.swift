import PrinceClockInCore
import SwiftUI

/// The menu bar item: a clock whose symbol shows the state, and the time left on the login it is
/// about, or the batch's progress while one runs. A dot after them says an update is waiting.
struct MenuBarLabel: View {
    let coordinator: Coordinator
    let updater: Updater

    var body: some View {
        let status = menuBarStatus(
            coordinator.model.state.logins, now: coordinator.now,
            leadTime: coordinator.model.state.settings.warningLeadTime, batch: coordinator.batch,
            hasFailure: coordinator.saveFailure != nil)
        HStack(spacing: 4) {
            Image(systemName: Self.symbolName(for: status))
            if let text = Self.text(for: status) {
                Text(text)
                    .monospacedDigit()
            }
            if updater.updateAvailable {
                Image(systemName: "circle.fill")
                    .imageScale(.small)
                    .accessibilityLabel("Update available")
            }
        }
    }

    /// Untinted, since the menu bar draws its label as a template image.
    private static func symbolName(for status: MenuBarStatus) -> String {
        switch status {
        case .loggingIn: "clock.arrow.circlepath"
        case .failure: "exclamationmark.triangle"
        case .expired: "clock.badge.xmark"
        case .expiring: "clock.badge.exclamationmark"
        case .ok, .noTimer: "clock"
        }
    }

    private static func text(for status: MenuBarStatus) -> String? {
        switch status {
        case .loggingIn(let progress): batchProgressText(progress)
        case .expiring(_, let remaining), .ok(_, let remaining): timeLeftText(remaining, locale: .current)
        case .failure, .expired, .noTimer: nil
        }
    }
}
