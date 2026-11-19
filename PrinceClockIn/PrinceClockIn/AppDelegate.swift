import AppKit
import PrinceClockInCore
import SwiftUI

/// Owns the app's AppKit side: the status item, the panel's popover, the Settings window and the
/// hidden main menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private static let settingsFrameName = "Settings"

    // Created with the delegate, before launch finishes, so a notification button that launched
    // the app finds its handler, and the timers run before the panel is first opened.
    private let appModel: AppModel
    private let updater: Updater
    private let popover = NSPopover()
    private let panelSession = PanelSession()
    private var statusItem: StatusItemController?
    private var settingsWindow: NSWindow?
    private let loginsPaneRequest = LoginsPaneRequest()

    override init() {
        appModel = AppModel()
        updater = Updater(coordinator: appModel.coordinator)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        statusItem = StatusItemController(
            coordinator: appModel.coordinator, updater: updater,
            togglePanel: { [weak self] in self?.togglePanel() }, openSettings: { [weak self] in self?.showSettings() })
        setUpPopover()
    }

    /// The menu bar an `LSUIElement` app never shows, there so its key equivalents work while the
    /// app is active: Settings… and Quit, and the Close and Edit commands Settings' fields need.
    private func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu()
        let settings = RightClickMenuItem.settings
        let quit = RightClickMenuItem.quit
        appMenu.addItem(withTitle: settings.title, action: #selector(settingsChosen), keyEquivalent: settings.keyEquivalent)
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: quit.title, action: #selector(NSApplication.terminate(_:)), keyEquivalent: quit.keyEquivalent)

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let mainMenu = NSMenu()
        for submenu in [appMenu, fileMenu, editMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        return mainMenu
    }

    @objc private func settingsChosen() {
        showSettings()
    }

    private func setUpPopover() {
        popover.behavior = .transient
        let panel = PanelView(
            appModel: appModel, updater: updater, session: panelSession,
            openSettings: { [weak self] in self?.showSettings() },
            editInSettings: { [weak self] in self?.showSettings(selecting: $0) },
            addLogins: { [weak self] in self?.showSettingsOpeningAddMenu() })
        let hosting = PanelHostingController(rootView: panel)
        hosting.sizingOptions = .preferredContentSize
        hosting.onCancel = { [weak self] in self?.panelCancelled() }
        popover.contentViewController = hosting
        popover.delegate = self
        NotificationCenter.default.addObserver(
            forName: NSPopover.didShowNotification, object: popover, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.panelDidShow() }
        }
        NotificationCenter.default.addObserver(
            forName: NSPopover.didCloseNotification, object: popover, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.panelDidClose() }
        }
    }

    /// The tiles take their order before the panel appears, so they don't re-sort once it is
    /// shown, and keep it until it next opens.
    func popoverWillShow(_ notification: Notification) {
        let coordinator = appModel.coordinator
        panelSession.open(order: coordinator.model.panelOrder(now: coordinator.now).map(\.id))
    }

    /// The panel's content is built once, so what it shows from the system is read on each showing.
    /// Its banners count as seen only from this reading of the notification permission on.
    private func panelDidShow() {
        appModel.coordinator.markPanelShown()
        panelSession.didShow()
        Task {
            await appModel.refreshNotificationPermission()
            panelSession.permissionRefreshed(showing: appModel.panelBanners)
        }
    }

    /// Escape that no control in the panel took: it cancels an open Set Timer, else closes the panel.
    private func panelCancelled() {
        let tiles = appModel.coordinator.model.logins(inOrder: panelSession.order).map(\.id)
        switch escapeResponse(openSetTimer: panelSession.openSetTimer, tiles: tiles) {
        case .cancelSetTimer(let id): panelSession.closeSetTimer(for: id)
        case .closePanel: popover.performClose(nil)
        }
    }

    private func panelDidClose() {
        statusItem?.button?.highlight(false)
        if panelSession.close() { appModel.dismissNotificationsBanner() }
    }

    private func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem?.button else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        button.highlight(true)
    }

    /// Keeps the panel open through the mouse-down of a click on the status item, which a
    /// transient popover would take as a click outside; the click's mouse-up then closes it.
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        guard let event = NSApp.currentEvent, event.type == .leftMouseDown,
              !event.modifierFlags.contains(.control),
              let button = statusItem?.button, event.window == button.window
        else { return true }
        return false
    }

    /// Shows the Settings window in front of other apps: the open one if it is open, else a new
    /// one, so its panes read the config files and the system again. It opens where and at the
    /// size the user last left it, else centred at its ideal size, on `pane`, else the pane last
    /// chosen.
    private func showSettings(on pane: SettingsPane? = nil) {
        if let pane { UserDefaults.standard.set(pane.rawValue, forKey: SettingsView.paneKey) }
        popover.performClose(nil)
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(
                appModel: appModel, updater: updater, loginsPaneRequest: loginsPaneRequest))
            // Only the minimum, so the window stays resizable and zoomable above it.
            hosting.sizingOptions = .minSize
            let window = NSWindow(contentViewController: hosting)
            window.title = "PrinceClockIn Settings"
            window.setContentSize(SettingsView.idealSize)
            if !window.setFrameUsingName(Self.settingsFrameName) { window.center() }
            window.setFrameAutosaveName(Self.settingsFrameName)
            window.delegate = self
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Edit in Settings…: Settings on Logins, with the tile's login selected.
    private func showSettings(selecting loginID: UUID) {
        loginsPaneRequest.loginToSelect = loginID
        showSettings(on: .logins)
    }

    /// Add Logins…: Settings on Logins, whose pane opens its + menu once it has read the config
    /// files.
    private func showSettingsOpeningAddMenu() {
        loginsPaneRequest.isAddMenuPending = true
        showSettings(on: .logins)
    }
}

extension AppDelegate: NSWindowDelegate {
    /// Lets go of the closing Settings window, and of its autosave name, which the next window
    /// takes, before anything can bring this one forward again. An Add Logins… it didn't get to
    /// answer is dropped, so the next window doesn't open the + menu unasked.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        window.setFrameAutosaveName("")
        settingsWindow = nil
        loginsPaneRequest.isAddMenuPending = false
    }
}
