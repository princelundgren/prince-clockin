import AppKit
import PrinceClockInCore
import SwiftUI

/// Where keyboard focus is in the panel, as far as its keys need to know. Tiles and buttons take
/// focus only with the user's Keyboard Navigation setting on; text fields always do.
enum PanelFocus: Hashable {
    case tile(UUID)
    case textField(UUID, PanelTextField)

    var tile: UUID? {
        if case .tile(let id) = self { id } else { nil }
    }

    var isTextField: Bool {
        if case .textField = self { true } else { false }
    }
}

/// A text field in a tile, of the login it belongs to.
enum PanelTextField: Hashable {
    case hours, minutes, loggedInAt, customHours, sessionLength
}

/// The panel's default buttons: the one prominent button, the one Return triggers, and the Set
/// Timer whose Cancel Escape triggers, as the core decides them.
struct PanelDefaults {
    let prominent: ProminentAction?
    let onReturn: ProminentAction?
    let cancelledByEscape: UUID?

    init(keys: PanelKeyContext) {
        prominent = keys.prominent
        onReturn = if case .perform(let action) = panelKeyResponse(to: .returnKey, in: keys) { action } else { nil }
        cancelledByEscape = switch escapeResponse(openSetTimer: keys.openSetTimer, tiles: keys.tiles) {
        case .cancelSetTimer(let id): id
        case .closePanel: nil
        }
    }
}

extension View {
    /// Return triggers this control while `isTarget`; a key equivalent, so it needs no focus.
    func returnKey(_ isTarget: Bool) -> some View {
        keyboardShortcut(isTarget ? .defaultAction : nil)
    }

    /// Escape triggers this control while `isTarget`; a key equivalent, so it needs no focus.
    func escapeKey(_ isTarget: Bool) -> some View {
        keyboardShortcut(isTarget ? .cancelAction : nil)
    }
}

/// Hosts the panel in its popover. The view controller sits in the responder chain behind the
/// panel's views, so the Escape key's cancel command reaches it when no control in the panel
/// takes it.
final class PanelHostingController: NSHostingController<PanelView> {
    var onCancel: () -> Void = {}

    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }
}
