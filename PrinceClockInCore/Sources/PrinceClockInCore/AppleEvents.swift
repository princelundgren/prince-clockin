import Carbon
import Foundation

/// Terminal's `do script` Apple event for `target`, which opens a new window running `command`.
/// The command travels as the event's direct parameter, as data, never as script source, so it
/// needs no quoting.
public func doScriptEvent(command: String, target: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
    let event = appleEvent(class: AEEventClass(kAECoreSuite), id: AEEventID(kAEDoScript), target: target)
    event.setParam(NSAppleEventDescriptor(string: command), forKeyword: AEKeyword(keyDirectObject))
    return event
}

/// The standard `activate` Apple event, which brings `target` to the front.
public func activateEvent(target: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
    appleEvent(class: AEEventClass(kAEMiscStandards), id: AEEventID(kAEActivate), target: target)
}

private func appleEvent(
    class eventClass: AEEventClass, id: AEEventID, target: NSAppleEventDescriptor
) -> NSAppleEventDescriptor {
    NSAppleEventDescriptor.appleEvent(
        withEventClass: eventClass, eventID: id, targetDescriptor: target,
        returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
}
