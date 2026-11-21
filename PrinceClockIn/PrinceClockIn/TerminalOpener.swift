import AppKit
import Carbon
import PrinceClockInCore

/// Why Terminal couldn't be given a custom login's command, other than a denied permission, which
/// is the core's `TerminalNotPermitted`.
enum TerminalOpenerError: LocalizedError {
    case notStarted
    case permissionCheckFailed(OSStatus)
    case eventFailed(Int)

    var errorDescription: String? {
        switch self {
        case .notStarted:
            "Terminal couldn't be started"
        case .permissionCheckFailed(let status):
            "Couldn't check the permission to control Terminal (error \(status))"
        case .eventFailed(let number):
            "Terminal didn't run the command (error \(number))"
        }
    }
}

/// Opens a custom login's command in a new Terminal window with a `do script` Apple event. The
/// command is the event's direct parameter, never script source, and is never written to a file
/// Terminal executes. Nothing here blocks the main thread or a thread of Swift's concurrency pool,
/// and once the call is cancelled Terminal is sent nothing more.
struct TerminalOpener: TerminalOpening {
    private static let terminalBundleID = "com.apple.Terminal"
    /// How long Terminal has to answer each event before the open fails.
    private static let replyTimeout: TimeInterval = 30

    func open(command: String) async throws {
        try await Self.launchTerminal()
        try Task.checkCancellation()
        let permission = await Self.automationPermission()
        try Task.checkCancellation()
        switch permission {
        case noErr: try await Self.send(command)
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

    /// On `blockingQueue`, as `AEDeterminePermissionToAutomateTarget`'s header asks: when the user
    /// hasn't answered yet, the call waits for their answer to the Automation prompt. Asks only when
    /// an answer is needed.
    private static func automationPermission() async -> OSStatus {
        let status = await onBlockingQueue { permission(askUserIfNeeded: false) }
        guard status == OSStatus(errAEEventWouldRequireUserConsent), !Task.isCancelled else { return status }
        return await onBlockingQueue { permission(askUserIfNeeded: true) }
    }

    private static func permission(askUserIfNeeded: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: terminalBundleID)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, askUserIfNeeded)
    }

    /// Brings Terminal to the front, then has it run `command`, each event waiting at most
    /// `replyTimeout` for Terminal's reply, on `blockingQueue`.
    private static func send(_ command: String) async throws {
        for isDoScript in [false, true] {
            try Task.checkCancellation()
            let errorNumber = await onBlockingQueue { sendEvent(doScript: isDoScript ? command : nil) }
            if let errorNumber { throw failure(errorNumber) }
        }
    }

    /// Sends `activate`, or `do script` with `command`, and waits for the reply: the error number
    /// of a failed send or of an error in the reply, else `nil`.
    private static func sendEvent(doScript command: String?) -> Int? {
        let target = NSAppleEventDescriptor(bundleIdentifier: terminalBundleID)
        let event = command.map { doScriptEvent(command: $0, target: target) } ?? activateEvent(target: target)
        let reply: NSAppleEventDescriptor
        do {
            reply = try event.sendEvent(options: .defaultOptions, timeout: replyTimeout)
        } catch let error as NSError {
            return error.code
        }
        guard let number = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value,
              number != 0
        else { return nil }
        return Int(number)
    }

    /// Where the calls that wait on Terminal or on the user run. Its threads come from Dispatch, not
    /// Swift's fixed-width concurrency pool, so an open the queue gave up on, still blocked in one of
    /// those calls, holds no pool thread. Cancelling a task doesn't interrupt a call already made.
    private static let blockingQueue = DispatchQueue(
        label: "PrinceClockIn.TerminalOpener", qos: .userInitiated, attributes: .concurrent)

    private static func onBlockingQueue<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            blockingQueue.async { continuation.resume(returning: work()) }
        }
    }

    private static func failure(_ number: Int) -> any Error {
        number == Int(errAEEventNotPermitted) ? TerminalNotPermitted() : TerminalOpenerError.eventFailed(number)
    }
}
