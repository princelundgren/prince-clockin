import PrinceClockInCore
import SwiftUI

/// The menu bar item: a clock whose badge shows the worst state, and the time left on the
/// soonest-expiring login, or which login is running during a batch.
struct MenuBarLabel: View {
    let coordinator: Coordinator

    var body: some View {
        let status = menuBarStatus(
            coordinator.model.state.logins, now: coordinator.now,
            leadTime: coordinator.model.state.settings.warningLeadTime)
        HStack(spacing: 4) {
            Image(systemName: Self.symbolName(for: status.severity))
            Text(menuBarText(status, batch: coordinator.batch))
                .monospacedDigit()
        }
    }

    /// Untinted, since the menu bar draws its label as a template image.
    private static func symbolName(for severity: Severity) -> String {
        switch severity {
        case .normal: "clock"
        case .expiring: "clock.badge.exclamationmark"
        case .expired: "clock.badge.xmark"
        }
    }
}
