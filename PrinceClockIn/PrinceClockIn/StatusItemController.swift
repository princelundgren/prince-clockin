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
    /// A design choice: the menu bar font's 13 pt drew the clock smaller than many menu bar icons.
    private static let symbolPointSize: CGFloat = 16

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let coordinator: Coordinator
    private let updater: Updater
    private let togglePanel: () -> Void
    private let openSettings: () -> Void
    /// The open right-click menu's items, which its menu items' tags index.
    private var menuItems: [RightClickMenuItem] = []
    /// The due logins the open menu's Log In to N Due counts, so a click starts the ones it named.
    private var menuDueIDs: [UUID] = []
    /// An image view, since in AppKit only it runs SF Symbol effects.
    private let symbolView = MenuBarImageView()
    private let dotView = MenuBarImageView()
    /// The symbol and the dot, centred in the button, where the button would draw its own image.
    private let contentView = MenuBarContentView()
    private var shownLabel: MenuBarLabel?
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
        if let button = statusItem.button {
            contentView.orientation = .horizontal
            contentView.alignment = .centerY
            contentView.spacing = Self.spacing
            contentView.addArrangedSubview(symbolView)
            contentView.addArrangedSubview(dotView)
            contentView.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(contentView)
            NSLayoutConstraint.activate([
                contentView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                contentView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ])
        }
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

    /// `Observations` yields after every tick, most often with the label unchanged.
    private func show(_ label: MenuBarLabel) {
        guard label != shownLabel else { return }
        shownLabel = label
        if label.symbolName != shownSymbolName {
            symbolView.image = NSImage(systemSymbolName: label.symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: Self.symbolPointSize, weight: .regular))
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
        // A blank image of the content's size: the system pads the item around it as around any
        // menu bar icon, and draws nothing, so the content view shows through.
        statusItem.button?.image = NSImage(size: contentView.fittingSize)
        statusItem.button?.setAccessibilityLabel(label.accessibilityLabel)
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

/// The status item's content, which leaves clicks to the button.
private final class MenuBarContentView: NSStackView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// An image in the status item's button that leaves VoiceOver to the button, which carries the
/// item's one label. It lays out by the whole image's width.
private final class MenuBarImageView: NSImageView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        imageScaling = .scaleNone
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A badged symbol's alignment rect leaves out the badge, which would make the item too narrow
    /// and push the dot into the badge.
    override var alignmentRectInsets: NSEdgeInsets {
        var insets = super.alignmentRectInsets
        insets.left = 0
        insets.right = 0
        return insets
    }
}
