import Foundation
import Testing
import PrinceClockInCore

/// Runs `argument` through a compiled `on echo…(x) / return x` handler, so what comes back is
/// exactly what the handler received. Needs no other app, and no Automation permission.
@MainActor
private func echo(_ argument: String, handler: String = "echo") throws -> String? {
    let script = try #require(NSAppleScript(source: "on \(handler)(x)\nreturn x\nend \(handler)"))
    var compileError: NSDictionary?
    let compiled = script.compileAndReturnError(&compileError)
    #expect(compiled, "compile failed: \(String(describing: compileError))")
    var runError: NSDictionary?
    let result = script.executeAppleEvent(handlerCallEvent(handler: handler, argument: argument), error: &runError)
    #expect(runError == nil, "handler call failed: \(String(describing: runError))")
    return result.stringValue
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
    @MainActor func handlerReceivesArgumentVerbatim(argument: String) throws {
        #expect(try echo(argument) == argument)
    }

    @Test @MainActor func mixedCaseHandlerNameIsCalled() throws {
        #expect(try echo("dev", handler: "openCommand") == "dev")
    }
}
