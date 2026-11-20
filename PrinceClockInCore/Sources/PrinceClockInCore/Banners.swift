import Foundation

/// A banner at the top of the panel, highest priority first in declaration order.
public enum Banner: Hashable, Sendable {
    /// The state file was unreadable or from a newer version, so it was set aside as `backup`.
    case stateSetAside(backup: URL)
    case saveFailed(reason: String)
    case notificationsOff

    /// The banner's text, one paragraph per line.
    public var lines: [String] {
        switch self {
        case .stateSetAside:
            ["PrinceClockIn couldn't use its saved logins (the file was unreadable or from a newer version), so it "
                + "started empty. The old file was kept."]
        case .saveFailed(let reason):
            ["Your changes couldn't be saved", reason, "They'll be lost when PrinceClockIn quits."]
        case .notificationsOff:
            ["Notifications are off, so only the menu bar shows that a login is about to expire."]
        }
    }

    /// The banner's buttons, in order.
    public var actions: [BannerAction] {
        switch self {
        case .stateSetAside: [.showInFinder, .dismiss]
        case .saveFailed: [.tryAgain]
        case .notificationsOff: [.openNotificationSettings]
        }
    }
}

/// A banner's button.
public enum BannerAction: Hashable, Sendable {
    /// Shows the set-aside state file in Finder.
    case showInFinder
    /// Hides the State set aside banner until the next launch.
    case dismiss
    /// Saves again, through the coordinator's `retrySave()`.
    case tryAgain
    /// Opens System Settings → Notifications.
    case openNotificationSettings

    public var title: String {
        switch self {
        case .showInFinder: "Show in Finder…"
        case .dismiss: "Dismiss"
        case .tryAgain: "Try Again"
        case .openNotificationSettings: "Open System Settings…"
        }
    }
}

/// Whether the Notifications off banner was on screen during one opening of the panel, so that
/// closing the panel dismisses it, even if a higher banner pushed it out before then. Banners count
/// only once this opening has read the notification permission, so a banner left from an earlier
/// reading never counts.
public struct NotificationsBannerSighting: Equatable, Sendable {
    private enum Phase: Equatable, Sendable {
        case closed
        case awaitingPermission
        case counting
    }

    private var phase = Phase.closed
    private var wasShown = false

    public init() {}

    public mutating func panelOpened() {
        phase = .awaitingPermission
        wasShown = false
    }

    /// This opening read the notification permission, and the panel shows `banners`. A reading
    /// that arrives after the panel closed is ignored.
    public mutating func permissionRefreshed(showing banners: [Banner]) {
        guard phase != .closed else { return }
        phase = .counting
        panelShows(banners)
    }

    /// The open panel shows `banners`.
    public mutating func panelShows(_ banners: [Banner]) {
        if phase == .counting, banners.contains(.notificationsOff) { wasShown = true }
    }

    /// The panel closed. Returns whether to dismiss the banner.
    public mutating func panelClosed() -> Bool {
        defer {
            phase = .closed
            wasShown = false
        }
        return wasShown
    }
}

/// Whether a dismissed Notifications off banner stays dismissed now that the permission reads
/// `notificationsAreOff`. A dismissal lasts only while notifications stay off, so the banner
/// appears once each time they are turned off.
public func notificationsBannerStaysDismissed(_ isDismissed: Bool, notificationsAreOff: Bool) -> Bool {
    isDismissed && notificationsAreOff
}

/// The panel's banners, highest first: at most two, so a third waits until one clears. State set
/// aside shows while `setAsideFile` is set, Save failed while `saveFailure` is, and Notifications
/// off while notifications are off, until the user has seen it once
/// (`isNotificationsBannerDismissed`).
public func panelBanners(
    setAsideFile: URL?, saveFailure: String?, notificationsAreOff: Bool, isNotificationsBannerDismissed: Bool
) -> [Banner] {
    let banners: [Banner?] = [
        setAsideFile.map(Banner.stateSetAside),
        saveFailure.map(Banner.saveFailed),
        notificationsAreOff && !isNotificationsBannerDismissed ? .notificationsOff : nil,
    ]
    return Array(banners.compactMap { $0 }.prefix(2))
}
