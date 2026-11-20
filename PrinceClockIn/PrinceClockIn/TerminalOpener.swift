import AppKit
import Carbon
import PrinceClockInCore

/// Why Terminal couldn't be given a custom login's command, other than a denied permission, which
/// is the core's `TerminalNotPermitted`.
enum TerminalOpenerError: LocalizedError {
    case notStarted
    case permissionCheckFailed(OSStatus)
    case scriptNotCompiled
    case scriptFailed(Int)

    var errorDescription: String? {
        switch self {
        case .notStarted:
            "Terminal couldn't be started"
        case .permissionCheckFailed(let status):
            "Couldn't check the permission to control Terminal (error \(status))"
        case .scriptNotCompiled:
            "PrinceClockIn couldn't build its script for Terminal"
        case .scriptFailed(let number):
            "Terminal didn't run the command (error \(number))"
        }
    }
}

/// Opens a custom login's command in a new Terminal window with a `do script` Apple event. The
/// command reaches the compiled script as a handler parameter, never as script source, and is
/// never written to a file Terminal executes.
struct TerminalOpener: TerminalOpening {
    private static let terminalBundleID = "com.apple.Terminal"
    private static let handlerName = "openCommand"
    // `activate` sits inside the `tell`, or it would bring PrinceClockIn to the front instead.
    private static let source = """
        on openCommand(theCommand)
            tell application "Terminal"
                activate
                do script theCommand
            end tell
        end openCommand
        """

    @MainActor private static let script: NSAppleScript? = {
        let script = NSAppleScript(source: source)
        return script?.compileAndReturnError(nil) == true ? script : nil
    }()

    func open(command: String) async throws {
        try await Self.launchTerminal()
        switch await Self.automationPermission() {
        case noErr: try await Self.run(command)
        case OSStatus(errAEEventNotPermitted): throw TerminalNotPermitted()
        case OSStatus(procNotFound): throw TerminalOpenerError.notStarted
        case let status: throw TerminalOpenerError.permissionCheckFailed(status)
        }
    }

    /// Launches Terminal, or finds it running, and returns once it has finished launching, since
    /// the permission check needs a running target.
    private static func launchTerminal() async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminalBundleID) else {
            throw TerminalOpenerError.notStarted
        }
        let app: NSRunningApplication
        do {
            app = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            throw TerminalOpenerError.notStarted
        }
        let (launched, sink) = AsyncStream.makeStream(of: Bool.self)
        let observation = app.observe(\.isFinishedLaunching, options: [.initial, .new]) { app, _ in
            sink.yield(app.isFinishedLaunching)
        }
        defer { observation.invalidate() }
        for await isFinished in launched where isFinished { return }
        throw CancellationError()
    }

    /// Off the main thread: the call can wait for the user's answer to the Automation prompt.
    @concurrent private static func automationPermission() async -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: terminalBundleID)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, true)
    }

    @MainActor private static func run(_ command: String) throws {
        guard let script else { throw TerminalOpenerError.scriptNotCompiled }
        var errorInfo: NSDictionary?
        _ = script.executeAppleEvent(handlerCallEvent(handler: handlerName, argument: command), error: &errorInfo)
        guard let errorInfo else { return }
        let number = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
        if number == Int(errAEEventNotPermitted) { throw TerminalNotPermitted() }
        throw TerminalOpenerError.scriptFailed(number)
    }
}
