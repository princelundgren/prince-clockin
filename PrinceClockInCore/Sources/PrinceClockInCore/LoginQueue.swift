import Foundation

/// Opens a custom login's command in a Terminal window, for the user to finish there.
public protocol TerminalOpening: Sendable {
    /// Returns once Terminal has the command. Throws when it can't be opened, such as when the user
    /// has denied the permission to control Terminal.
    func open(command: String) async throws
}

/// Why a login in the queue didn't succeed.
public enum LoginFailure: Equatable, Sendable {
    /// The named CLI isn't on the login shell's `PATH`.
    case cliNotFound(String)
    /// The CLI exited with this non-zero status.
    case exitCode(Int32)
    /// The login ran past its timeout: the CLI was ended, or a custom login got no Done.
    case timedOut
    /// The user cancelled the run while this login was running or waiting for Done.
    case cancelled
    /// The CLI couldn't be started; the string names it and the system's reason.
    case launchFailed(String)
    /// Terminal couldn't be opened for a custom login; the string is the system's reason.
    case terminalFailed(String)
}

extension LoginFailure {
    /// What the login's row says went wrong.
    public var message: String {
        switch self {
        case .cliNotFound(let executable): "\(executable) not found on your login shell's PATH"
        case .exitCode(let code): "The login exited with status \(code)"
        case .timedOut: "The login timed out"
        case .cancelled: "Cancelled"
        case .launchFailed(let reason), .terminalFailed(let reason): reason
        }
    }
}

/// What the queue reports, in order. A run is the logins started from an idle queue until it is
/// empty again or cancelled; it ends with `.finished`.
public enum QueueEvent: Equatable, Sendable {
    /// The logins waiting to run changed by an enqueue, a removal or a cancel, not by one
    /// starting: `ids` are the queued logins in order, and `total` is the run's, as in `started`.
    /// While Cancel All ends a run, `ids` are the next run's and the ending run's total stays.
    case queued(ids: [UUID], total: Int)
    /// `total` is the logins started plus queued in this run, so it grows when more are enqueued
    /// and shrinks when a queued one is removed.
    case started(id: UUID, position: Int, total: Int)
    /// `at` is the injected clock's time when the login ended.
    case succeeded(id: UUID, at: Date)
    /// The login ended without signing in. The run goes on to the next login, unless the whole run
    /// was cancelled.
    case failed(id: UUID, reason: LoginFailure)
    /// A custom login waits for `confirmCustomDone(id:)`, or its timeout.
    case waitingForDone(id: UUID)
    /// The run is over: the queue emptied or was cancelled. Logins enqueued afterwards start a new
    /// run at position 1.
    case finished
}

/// Runs logins one at a time, in the order they were enqueued. AWS and Databricks logins run their
/// CLI through `runner`; a custom login opens its command in Terminal, if it has one, and waits for
/// the user's Done. Every login is ended at its timeout, so a forgotten one can't block the queue.
public actor LoginQueue {
    private struct Pending {
        let login: Login
        let timeout: TimeInterval
    }

    private struct Running {
        let loginID: UUID
        let task: Task<Void, Never>
        var isCancelled = false
    }

    private enum DoneOutcome {
        case done, timedOut, cancelled
    }

    private struct WaitingForDone {
        let loginID: UUID
        let token: UUID
        let continuation: CheckedContinuation<DoneOutcome, Never>
    }

    /// Every event, in order. There is one stream per queue, for one consumer.
    public nonisolated let events: AsyncStream<QueueEvent>

    private let continuation: AsyncStream<QueueEvent>.Continuation
    private let runner: ProcessRunning
    private let pathResolver: ShellPathResolver
    private let terminal: TerminalOpening
    private let clock: @Sendable () -> Date

    private var pending: [Pending] = []
    private var running: Running?
    private var isRunCancelled = false
    private var startedInRun = 0
    private var waitingForDone: WaitingForDone?
    private var outputs: [UUID: String] = [:]

    /// An empty, idle queue. `runner` runs the CLIs, found on the `PATH` from `pathResolver`;
    /// `terminal` opens custom commands; `clock` gives the time a login succeeded.
    public init(
        runner: ProcessRunning, pathResolver: ShellPathResolver, terminal: TerminalOpening,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        (events, continuation) = AsyncStream.makeStream(of: QueueEvent.self)
        self.runner = runner
        self.pathResolver = pathResolver
        self.terminal = terminal
        self.clock = clock
    }

    deinit {
        continuation.finish()
    }

    /// Adds `logins` to the end of the queue and starts the first if none is running. A login
    /// already queued, or running and not cancelled, is skipped. `timeout` is in seconds.
    public func enqueue(_ logins: [Login], timeout: TimeInterval) {
        let before = pending.count
        for login in logins where !isQueuedOrRunning(login.id) {
            pending.append(Pending(login: login, timeout: timeout))
        }
        if pending.count != before { emitQueued() }
        if running == nil { startNext() }
    }

    /// Clears the queue and ends the running login, terminating its process or ending its wait for
    /// Done; the run then reports it cancelled and finishes. Does nothing when no login is running.
    public func cancel() {
        guard running != nil else { return }
        if !pending.isEmpty {
            pending.removeAll()
            emitQueued()
        }
        isRunCancelled = true
        cancelRunning()
    }

    /// Takes login `id` out of the run. A queued login leaves the queue, so the total shrinks. The
    /// running login is ended as `cancel()` ends it, but alone: it reports cancelled and the run
    /// goes on to the next login. Does nothing for a login neither queued nor running.
    public func remove(id: UUID) {
        let before = pending.count
        pending.removeAll { $0.login.id == id }
        if pending.count != before { emitQueued() }
        guard running?.loginID == id else { return }
        cancelRunning()
    }

    /// The user's Done for a custom login. Does nothing unless that login is waiting for it.
    public func confirmCustomDone(id: UUID) {
        endWaitForDone(with: .done) { $0.loginID == id }
    }

    /// The output of the login's last run, if that run produced any. Kept in memory only.
    public func lastOutput(id: UUID) -> String? {
        outputs[id]
    }

    private func isQueuedOrRunning(_ id: UUID) -> Bool {
        pending.contains { $0.login.id == id } || (running?.loginID == id && running?.isCancelled == false)
    }

    private func cancelRunning() {
        running?.isCancelled = true
        running?.task.cancel()
        endWaitForDone(with: .cancelled) { _ in true }
    }

    private func startNext() {
        guard !pending.isEmpty else { return }
        let next = pending.removeFirst()
        startedInRun += 1
        let id = next.login.id
        emit(.started(id: id, position: startedInRun, total: startedInRun + pending.count))
        running = Running(loginID: id, task: Task { await run(next) })
    }

    private func run(_ next: Pending) async {
        let id = next.login.id
        outputs[id] = nil
        let result = await perform(next.login, timeout: next.timeout)
        emit(result)
        running = nil
        if isRunCancelled || pending.isEmpty {
            emit(.finished)
            isRunCancelled = false
            startedInRun = 0
        }
        startNext()
    }

    private func perform(_ login: Login, timeout: TimeInterval) async -> QueueEvent {
        guard let command = loginCommand(for: login.kind) else {
            return await performCustom(
                id: login.id, command: login.kind.terminalCommand, timeout: timeout)
        }
        return await performCLI(id: login.id, command: command, timeout: timeout)
    }

    private func performCLI(
        id: UUID, command: LoginCommand, timeout: TimeInterval
    ) async -> QueueEvent {
        let path = await pathResolver.resolvePath()
        if Task.isCancelled { return .failed(id: id, reason: .cancelled) }
        guard let executable = path.locate(command.executable) else {
            return .failed(id: id, reason: .cliNotFound(command.executable))
        }
        let environment = path.childEnvironment(base: ProcessInfo.processInfo.environment)
        let outcome = await runner.run(
            executable: executable, arguments: command.arguments, environment: environment,
            timeout: .seconds(timeout))
        switch outcome {
        case .exited(0, let output):
            outputs[id] = output
            return .succeeded(id: id, at: clock())
        case .exited(let code, let output):
            outputs[id] = output
            return .failed(id: id, reason: .exitCode(code))
        case .timedOut(let output):
            outputs[id] = output
            return .failed(id: id, reason: .timedOut)
        case .cancelled:
            return .failed(id: id, reason: .cancelled)
        case .launchFailed(let message):
            return .failed(id: id, reason: .launchFailed(message))
        }
    }

    private func performCustom(
        id: UUID, command: String?, timeout: TimeInterval
    ) async -> QueueEvent {
        if Task.isCancelled { return .failed(id: id, reason: .cancelled) }
        if let command {
            do {
                try await terminal.open(command: command)
            } catch {
                if Task.isCancelled { return .failed(id: id, reason: .cancelled) }
                return .failed(id: id, reason: .terminalFailed(error.localizedDescription))
            }
            if Task.isCancelled { return .failed(id: id, reason: .cancelled) }
        }
        switch await waitForDone(id: id, timeout: timeout) {
        case .done: return .succeeded(id: id, at: clock())
        case .timedOut: return .failed(id: id, reason: .timedOut)
        case .cancelled: return .failed(id: id, reason: .cancelled)
        }
    }

    private func waitForDone(id: UUID, timeout: TimeInterval) async -> DoneOutcome {
        let token = UUID()
        let timer = Task {
            do {
                try await Task.sleep(for: .seconds(timeout))
            } catch {
                return
            }
            endWaitForDone(with: .timedOut) { $0.token == token }
        }
        defer { timer.cancel() }
        emit(.waitingForDone(id: id))
        return await withCheckedContinuation { continuation in
            waitingForDone = WaitingForDone(loginID: id, token: token, continuation: continuation)
        }
    }

    private func endWaitForDone(with outcome: DoneOutcome, if matches: (WaitingForDone) -> Bool) {
        guard let waiting = waitingForDone, matches(waiting) else { return }
        waitingForDone = nil
        waiting.continuation.resume(returning: outcome)
    }

    private func emitQueued() {
        let total = isRunCancelled ? startedInRun : startedInRun + pending.count
        emit(.queued(ids: pending.map(\.login.id), total: total))
    }

    private func emit(_ event: QueueEvent) {
        continuation.yield(event)
    }
}

private extension LoginKind {
    /// A custom login's command; `nil` for one without a command and for every other kind.
    var terminalCommand: String? {
        if case .custom(let command) = self { command } else { nil }
    }
}
