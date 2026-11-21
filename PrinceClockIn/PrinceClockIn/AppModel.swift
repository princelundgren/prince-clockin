import AppKit
import Observation
import PrinceClockInCore
import UserNotifications

/// Builds the coordinator with the real system services and drives it: a tick at each deadline the
/// coordinator gives, on a change in the AWS cache directory, on wake, clock and time-zone changes,
/// and notification clicks. It makes no decisions of its own.
@MainActor
@Observable
final class AppModel: NSObject, UNUserNotificationCenterDelegate {
    /// How late a deadline's tick may run so the system can group it with other wake-ups: a
    /// notification or a shown minute that much late goes unnoticed.
    private static let tickTolerance: TimeInterval = 1
    private static let notificationsBannerDismissedKey = "notificationsBannerDismissed"

    let coordinator: Coordinator
    /// The user's home directory, which Settings abbreviates to `~` in a config file's path.
    let homeDirectory: URL
    /// Whether the user has denied notifications, so the panel and settings can say so.
    private(set) var notificationsAreOff = false
    /// Whether the panel was closed after showing the Notifications off banner, which then shows
    /// no more until notifications are on again; Settings still says they are off.
    private(set) var isNotificationsBannerDismissed =
        UserDefaults.standard.bool(forKey: AppModel.notificationsBannerDismissedKey)

    /// Whether the panel is shown.
    var isPanelShown = false
    /// Whether the Settings window is open.
    var isSettingsShown = false
    /// Opens the panel, for a click on a notification itself.
    @ObservationIgnored var openPanel: (() -> Void)?
    /// Whether VoiceOver runs, which reads the menu bar item's label with its time left.
    private var isVoiceOverOn = NSWorkspace.shared.isVoiceOverEnabled

    @ObservationIgnored private var tickTimer: Timer?
    /// Held while a tick timer waits, so App Nap doesn't delay a windowless app's deadline.
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var voiceOverObservation: NSKeyValueObservation?
    @ObservationIgnored private var awsCacheWatcher: AWSCacheWatcher?

    override init() {
        let environment = ProcessInfo.processInfo.environment
        let runner = FoundationProcessRunner()
        let pathResolver = ShellPathResolver(runner: runner, shell: Self.loginShell(), environment: environment)
        let queue = LoginQueue(runner: runner, pathResolver: pathResolver, terminal: TerminalOpener())
        let home = URL(
            filePath: environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory(),
            directoryHint: .isDirectory)
        homeDirectory = home
        coordinator = Coordinator(
            store: StateStore(directory: Self.stateDirectory()),
            queue: queue,
            pathResolver: pathResolver,
            checker: DatabricksChecker(runner: runner, pathResolver: pathResolver),
            aws: AWSCacheFileReader(cacheDirectory: home.appending(path: ".aws/sso/cache")),
            notifier: SystemNotifier(),
            approvals: UserDefaultsApprovals(),
            configPaths: .standard(environment: environment),
            clock: Date.init)
        super.init()
        // Set before launch finishes, so a notification button that launched the app isn't lost.
        UNUserNotificationCenter.current().delegate = self
        SystemNotifier.registerCategories()
        observeSystemChanges()
        Task {
            await SystemNotifier.requestAuthorization()
            await refreshNotificationPermission()
        }
        // No timer or cache change ticks before the coordinator has started and taken its baseline.
        Task {
            await coordinator.start()
            await coordinator.tick(calendar: .current)
            scheduleTicks()
            awsCacheWatcher = AWSCacheWatcher(directory: home.appending(path: ".aws/sso/cache")) { [weak self] in
                Task { await self?.coordinator.tick(calendar: .current) }
            }
        }
    }

    /// Reads the notification permission again, since the user can change it in System Settings.
    /// Notifications found on again end the banner's dismissal, so a later turn-off shows it again.
    func refreshNotificationPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsAreOff = settings.authorizationStatus == .denied
        if !notificationsBannerStaysDismissed(isNotificationsBannerDismissed, notificationsAreOff: notificationsAreOff) {
            isNotificationsBannerDismissed = false
            UserDefaults.standard.removeObject(forKey: Self.notificationsBannerDismissedKey)
        }
    }

    /// The panel's banners now, highest first.
    var panelBanners: [Banner] {
        PrinceClockInCore.panelBanners(
            setAsideFile: coordinator.loadNotice, saveFailure: coordinator.saveFailure,
            notificationsAreOff: notificationsAreOff, isNotificationsBannerDismissed: isNotificationsBannerDismissed)
    }

    /// The panel closed after showing the Notifications off banner, so it shows no more.
    func dismissNotificationsBanner() {
        isNotificationsBannerDismissed = true
        UserDefaults.standard.set(true, forKey: Self.notificationsBannerDismissedKey)
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Shown, with its sound, even while the panel or Settings is open, which makes the app active
    /// and would otherwise hide it.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let actionIdentifier = response.actionIdentifier
        let loginIDs = response.notification.request.content.userInfo[SystemNotifier.loginIDsKey] as? [String] ?? []
        await handleNotificationAction(actionIdentifier: actionIdentifier, loginIDs: loginIDs)
    }

    // MARK: Private

    private func handleNotificationAction(actionIdentifier: String, loginIDs: [String]) {
        let tracked = Set(coordinator.model.state.logins.map(\.id))
        switch notificationAction(actionIdentifier: actionIdentifier, loginIDs: loginIDs) {
        case .logIn(let ids):
            let stillTracked = ids.filter(tracked.contains)
            if !stillTracked.isEmpty { coordinator.logIn(stillTracked) }
        case .customDone(let id):
            if tracked.contains(id) { coordinator.confirmCustomDone(id: id) }
        case .openPanel:
            openPanel?()
        case nil:
            break
        }
    }

    private var shownTimes: ShownTimes {
        if isPanelShown || isSettingsShown { return .all }
        return isVoiceOverOn ? .menuBarLabel : .none
    }

    /// Keeps one tick timer armed at the coordinator's next deadline, moved whenever the logins,
    /// the last tick's time or what is shown changes.
    private func scheduleTicks() {
        Task { [weak self] in
            let deadlines = Observations { [weak self] in
                self.flatMap { $0.coordinator.nextTickDeadline(shown: $0.shownTimes, calendar: .current) }
            }
            for await deadline in deadlines {
                self?.armTick(at: deadline)
            }
        }
    }

    private func armTick(at deadline: Date?) {
        tickTimer?.invalidate()
        tickTimer = nil
        guard let deadline else {
            activity.map(ProcessInfo.processInfo.endActivity)
            activity = nil
            return
        }
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "Timing logins and notifying before they expire")
        }
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.coordinator.tick(calendar: .current) }
        }
        timer.tolerance = Self.tickTolerance
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func observeSystemChanges() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.coordinator.systemDidWake()
                await self?.coordinator.tick(calendar: .current)
            }
        }
        let changes: [(NotificationCenter, Notification.Name)] = [
            (.default, .NSSystemClockDidChange),
            (.default, .NSSystemTimeZoneDidChange),
        ]
        for (center, name) in changes {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.coordinator.tick(calendar: .current) }
            }
        }
        voiceOverObservation = NSWorkspace.shared.observe(\.isVoiceOverEnabled) { [weak self] workspace, _ in
            let isOn = workspace.isVoiceOverEnabled
            Task { @MainActor in self?.isVoiceOverOn = isOn }
        }
    }

    /// The user's login shell from the user database, since a GUI app may not have `SHELL`.
    private static func loginShell() -> URL {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else {
            return URL(filePath: "/bin/zsh")
        }
        return URL(filePath: String(cString: shell))
    }

    private static func stateDirectory() -> URL {
        URL.applicationSupportDirectory.appending(path: "PrinceClockIn", directoryHint: .isDirectory)
    }
}
