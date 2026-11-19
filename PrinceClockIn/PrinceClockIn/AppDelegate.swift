import AppKit
import PrinceClockInCore
import SwiftUI

/// Owns the app's AppKit side: the status item, the panel's popover and the Settings window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    // Created with the delegate, before launch finishes, so a notification button that launched
    // the app finds its handler, and the timers run before the panel is first opened.
    private let appModel = AppModel()
    private let updater = Updater()
    private let popover = NSPopover()
    private var statusItem: StatusItemController?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController(
            coordinator: appModel.coordinator, updater: updater,
            togglePanel: { [weak self] in self?.togglePanel() }, openSettings: { [weak self] in self?.showSettings() })
        setUpPopover()
    }

    private func setUpPopover() {
        popover.behavior = .transient
        let panel = PanelView(appModel: appModel, updater: updater, openSettings: { [weak self] in self?.showSettings() })
        let hosting = NSHostingController(rootView: panel)
        hosting.sizingOptions = .preferredContentSize
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
            Task { @MainActor in self?.statusItem?.button?.highlight(false) }
        }
    }

    /// The panel's content is built once, so what it shows from the system is read on each showing.
    private func panelDidShow() {
        appModel.coordinator.markPanelShown()
        Task { await appModel.refreshNotificationPermission() }
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

    /// Shows the Settings window, the same one each time, in front of other apps.
    private func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            settingsWindow = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(appModel: appModel)))
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
