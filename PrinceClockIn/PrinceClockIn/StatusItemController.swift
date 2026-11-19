import AppKit
import Observation
import PrinceClockInCore

/// The menu bar item: a template image of the state's symbol, the time left or the batch's
/// progress, and a dot when an update waits, redrawn whenever the core's label changes. A click
/// toggles the panel; a right click, or a Control-click, opens the right-click menu.
@MainActor
final class StatusItemController: NSObject {
    private static let spacing: CGFloat = 4
    private static let dotDiameter: CGFloat = 5

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let coordinator: Coordinator
    private let updater: Updater
    private let togglePanel: () -> Void
    private let openSettings: () -> Void
    /// The open right-click menu's items, which its menu items' tags index.
    private var menuItems: [RightClickMenuItem] = []
    /// The due logins the open menu's Log In to N Due counts, so a click starts the ones it named.
    private var menuDueIDs: [UUID] = []
    private let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)

    var button: NSStatusBarButton? { statusItem.button }

    init(
        coordinator: Coordinator, updater: Updater, togglePanel: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.updater = updater
        self.togglePanel = togglePanel
        self.openSettings = openSettings
        super.init()
        statusItem.behavior = .terminationOnRemoval
        // Shown at every launch, so opening the app again after its item was removed brings it back.
        statusItem.isVisible = true
        statusItem.button?.target = self
        statusItem.button?.action = #selector(buttonClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        Task { [weak self] in
            let labels = Observations {
                menuBarLabel(
                    for: coordinator.menuBarStatus, logins: coordinator.model.state.logins,
                    leadTime: coordinator.model.state.settings.warningLeadTime, updateVersion: updater.updateVersion,
                    locale: .current)
            }
            for await label in labels {
                self?.show(label)
            }
        }
    }

    @objc private func buttonClicked() {
        // A Control-click arrives as a left mouse-up with Control held.
        let event = NSApp.currentEvent
        let isSecondaryClick = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        if isSecondaryClick {
            showMenu()
        } else {
            togglePanel()
        }
    }

    /// Opens the right-click menu, built for the state at this moment.
    private func showMenu() {
        statusItem.menu = makeMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func makeMenu() -> NSMenu {
        menuDueIDs = coordinator.model.dueLogins(now: coordinator.now).map(\.id)
        menuItems = rightClickMenu(
            dueCount: menuDueIDs.count, isBatchRunning: coordinator.batch != nil,
            updateVersion: updater.updateVersion)
        let menu = NSMenu()
        for (index, item) in menuItems.enumerated() {
            if item == .separator {
                menu.addItem(.separator())
                continue
            }
            let menuItem = NSMenuItem(title: item.title, action: #selector(menuItemChosen), keyEquivalent: item.keyEquivalent)
            menuItem.target = self
            menuItem.tag = index
            menu.addItem(menuItem)
        }
        return menu
    }

    @objc private func menuItemChosen(_ sender: NSMenuItem) {
        switch menuItems[sender.tag] {
        case .logInToDue: coordinator.logIn(menuDueIDs)
        case .installUpdate, .checkForUpdates: updater.checkForUpdates()
        case .settings: openSettings()
        case .reportIssue: NSWorkspace.shared.open(AppLinks.reportIssue)
        case .quit: NSApp.terminate(nil)
        case .separator: break
        }
    }

    private func show(_ label: MenuBarLabel) {
        guard let button = statusItem.button else { return }
        button.image = image(for: label)
        button.setAccessibilityLabel(label.accessibilityLabel)
    }

    /// One template image of the whole label, so the menu bar tints it for its appearance. The
    /// text gets the width of the state's widest sample, and the dot follows that width, so
    /// nothing moves as the time counts down.
    private func image(for label: MenuBarLabel) -> NSImage {
        let height = NSStatusBar.system.thickness
        let symbol = NSImage(systemSymbolName: label.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular))
        let symbolSize = symbol?.size ?? .zero
        let text = label.text.map { NSAttributedString(string: $0, attributes: [.font: font, .foregroundColor: NSColor.black]) }
        // The real text counts too, for a time longer than the samples allow (over 99 days).
        let textWidth = ([text?.size().width ?? 0] + label.widthSamples.map(measure)).max() ?? 0
        var width = symbolSize.width
        if text != nil { width += Self.spacing + textWidth }
        if label.showsUpdateDot { width += Self.spacing + Self.dotDiameter }

        let image = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { _ in
            symbol?.draw(in: NSRect(
                x: 0, y: (height - symbolSize.height) / 2, width: symbolSize.width, height: symbolSize.height))
            var x = symbolSize.width
            if let text {
                text.draw(at: NSPoint(x: x + Self.spacing, y: (height - text.size().height) / 2))
                x += Self.spacing + textWidth
            }
            if label.showsUpdateDot {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(
                    x: x + Self.spacing, y: (height - Self.dotDiameter) / 2,
                    width: Self.dotDiameter, height: Self.dotDiameter)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private func measure(_ text: String) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: font]).size().width
    }
}
