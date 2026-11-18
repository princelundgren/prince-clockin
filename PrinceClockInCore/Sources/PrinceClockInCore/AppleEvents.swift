import Carbon
import Foundation

/// The Apple event that calls the AppleScript handler `handler` with `argument` as its one
/// parameter, for `NSAppleScript.executeAppleEvent(_:error:)` on a script that defines it. The
/// argument travels as data, never as script source, so it needs no quoting.
public func handlerCallEvent(handler: String, argument: String) -> NSAppleEventDescriptor {
    let event = NSAppleEventDescriptor.appleEvent(
        withEventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
        targetDescriptor: .currentProcess(), returnID: AEReturnID(kAutoGenerateReturnID),
        transactionID: AETransactionID(kAnyTransactionID))
    event.setParam(NSAppleEventDescriptor(string: handler), forKeyword: AEKeyword(keyASSubroutineName))
    let arguments = NSAppleEventDescriptor.list()
    arguments.insert(NSAppleEventDescriptor(string: argument), at: 1)
    event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))
    return event
}
