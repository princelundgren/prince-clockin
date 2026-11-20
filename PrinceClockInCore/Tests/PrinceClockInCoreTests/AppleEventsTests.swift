import Carbon
import Foundation
import Testing
import PrinceClockInCore

private func terminal() -> NSAppleEventDescriptor {
    NSAppleEventDescriptor(bundleIdentifier: "com.apple.Terminal")
}

@Suite struct AppleEventsTests {
    @Test(arguments: [
        "aws sso login --sso-session=dev",
        #"say "hi" 'there'"#,
        #"back\slash \\ \n"#,
        "line one\nline two\r\nline three",
        "echo $(whoami); rm -rf ~ `id`",
        "",
    ])
    func doScriptCarriesTheCommandVerbatim(command: String) {
        let event = doScriptEvent(command: command, target: terminal())

        #expect(event.eventClass == AEEventClass(kAECoreSuite))
        #expect(event.eventID == AEEventID(kAEDoScript))
        #expect(event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue == command)
        #expect(event.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr))?.data == terminal().data)
    }

    @Test func activateTargetsTheAppWithNoParameters() {
        let event = activateEvent(target: terminal())

        #expect(event.eventClass == AEEventClass(kAEMiscStandards))
        #expect(event.eventID == AEEventID(kAEActivate))
        #expect(event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) == nil)
        #expect(event.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr))?.data == terminal().data)
    }
}
