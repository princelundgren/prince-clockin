import AppKit
import Observation
import PrinceClockInCore

/// The menu bar item: the state's symbol, pulsing while logging in, and a dot when an update waits,
/// updated whenever the core's label changes. A click toggles the panel; a right click, or a
/// Control-click, opens the right-click menu.
@MainActor
final class StatusItemController: NSObject {
    private static let spacing: CGFloat = 4
    private static let dotDiameter: CGFloat = 5
    private static let horizontalPadding: CGFloat = 8

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let coordinator: Coordinator
    private let updater: Updater
    private let togglePanel: () -> Void
    private let openSettings: () -> Void
    /// The open right-click menu's items, which its menu items' tags index.
    private var menuItems: [RightClickMenuItem] = []
    /// The due logins the open menu's Log In to N Due counts, so a click starts the ones it named.
    private var menuDueIDs: [UUID] = []
    private let symbolPointSize = NSFont.menuBarFont(ofSize: 0).pointSize
    /// An image view, since in AppKit only it runs SF Symbol effects.
    private let symbolView = MenuBarImageView()
    private let dotView = MenuBarImageView()
    private var shownSymbolName: String?
    private var isPulseRunning = false

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
        dotView.image = Self.dotImage()
        statusItem.button?.addSubview(symbolView)
        statusItem.button?.addSubview(dotView)
        Task { [weak self] in
            let labels = Observations {
                menuBarLabel(
                    for: coordinator.menuBarStatus, logins: coordinator.model.state.logins,
                    updateVersion: updater.updateVersion, locale: .current)
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
            updateVersion: updater.updateVersion, isRelaunchPostponed: updater.isRelaunchPostponed)
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
        if label.symbolName != shownSymbolName {
            symbolView.image = NSImage(systemSymbolName: label.symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .regular))
            shownSymbolName = label.symbolName
        }
        if label.isPulsing != isPulseRunning {
            if label.isPulsing {
                symbolView.addSymbolEffect(.pulse, options: .repeat(.continuous))
            } else {
                symbolView.removeAllSymbolEffects()
            }
            isPulseRunning = label.isPulsing
        }
        dotView.isHidden = !label.showsUpdateDot
        layOut()
        statusItem.button?.setAccessibilityLabel(label.accessibilityLabel)
    }

    /// Sizes the item to the symbol, and the dot when shown, and places both in the button.
    private func layOut() {
        let height = NSStatusBar.system.thickness
        let symbolWidth = symbolView.image?.size.width ?? 0
        var width = symbolWidth
        if !dotView.isHidden { width += Self.spacing + Self.dotDiameter }
        statusItem.length = ceil(width) + 2 * Self.horizontalPadding
        symbolView.frame = NSRect(x: Self.horizontalPadding, y: 0, width: symbolWidth, height: height)
        dotView.frame = NSRect(
            x: Self.horizontalPadding + symbolWidth + Self.spacing, y: (height - Self.dotDiameter) / 2,
            width: Self.dotDiameter, height: Self.dotDiameter)
    }

    private static func dotImage() -> NSImage {
        let image = NSImage(size: NSSize(width: dotDiameter, height: dotDiameter), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// An image in the status item's button that leaves clicks and VoiceOver to the button, which
/// carries the item's one label.
private final class MenuBarImageView: NSImageView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        imageScaling = .scaleNone
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
