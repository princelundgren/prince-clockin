import AppKit
import Observation
import PrinceClockInCore
import UserNotifications

/// Builds the coordinator with the real system services and drives it: the 30-second tick, wake,
/// clock and time-zone changes, and notification buttons. It makes no decisions of its own.
@MainActor
@Observable
final class AppModel: NSObject, UNUserNotificationCenterDelegate {
    private static let tickInterval: TimeInterval = 30
    private static let tickTolerance: TimeInterval = 5

    let coordinator: Coordinator
    /// Whether the user has denied notifications, so the panel and settings can say so.
    private(set) var notificationsAreOff = false

    /// Held for the app's life, so App Nap doesn't coalesce the tick timer of a windowless app.
    @ObservationIgnored private let activity: NSObjectProtocol

    override init() {
        let environment = ProcessInfo.processInfo.environment
        let runner = FoundationProcessRunner()
        let pathResolver = ShellPathResolver(runner: runner, shell: Self.loginShell(), environment: environment)
        let queue = LoginQueue(runner: runner, pathResolver: pathResolver, terminal: TerminalOpener())
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        coordinator = Coordinator(
            store: StateStore(directory: Self.stateDirectory()),
            queue: queue,
            pathResolver: pathResolver,
            checker: DatabricksChecker(runner: runner, pathResolver: pathResolver),
            aws: AWSCacheFileReader(cacheDirectory: URL(filePath: home).appending(path: ".aws/sso/cache")),
            notifier: SystemNotifier(),
            approvals: UserDefaultsApprovals(),
            configPaths: .standard(environment: environment),
            clock: Date.init)
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Timing logins and warning before they expire")
        super.init()
        // Set before launch finishes, so a notification button that launched the app isn't lost.
        UNUserNotificationCenter.current().delegate = self
        SystemNotifier.registerCategories()
        startTicking()
        observeSystemChanges()
        Task {
            await SystemNotifier.requestAuthorization()
            await refreshNotificationPermission()
        }
        Task {
            await coordinator.start()
            await tick()
        }
    }

    /// Reads the notification permission again, since the user can change it in System Settings.
    func refreshNotificationPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsAreOff = settings.authorizationStatus == .denied
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Shown even while the panel is open, which makes the app active and would otherwise hide it.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
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
        case nil:
            break
        }
    }

    private func tick() async {
        await coordinator.tick()
        await refreshNotificationPermission()
    }

    private func startTicking() {
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        timer.tolerance = Self.tickTolerance
        RunLoop.main.add(timer, forMode: .common)
    }

    private func observeSystemChanges() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.coordinator.systemDidWake()
                await self?.tick()
            }
        }
        let changes: [(NotificationCenter, Notification.Name)] = [
            (.default, .NSSystemClockDidChange),
            (.default, .NSSystemTimeZoneDidChange),
        ]
        for (center, name) in changes {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.tick() }
            }
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
