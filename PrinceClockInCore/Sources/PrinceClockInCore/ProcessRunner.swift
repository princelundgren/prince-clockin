import Foundation
import Synchronization

/// How a run of an external process ended.
public enum ProcessOutcome: Equatable, Sendable {
    /// The process exited by itself. `output` is the last 64 KB of stdout and stderr together.
    case exited(code: Int32, output: String)
    /// The process was ended by a signal it didn't catch, not by the runner. `output` is as for
    /// `exited`.
    case signalled(signal: Int32, output: String)
    /// The process ran past the timeout and was terminated. `output` is what it had written, as for
    /// `exited`.
    case timedOut(output: String)
    /// The calling task was cancelled, and the process, if launched, was terminated.
    case cancelled
    /// The process could not be started. The string names the executable and the system's reason.
    case launchFailed(String)
}

public protocol ProcessRunning: Sendable {
    /// Runs `executable` to its end, or until `timeout`. Cancelling the calling task terminates the
    /// child and returns `.cancelled`.
    func run(
        executable: URL, arguments: [String], environment: [String: String], timeout: Duration
    ) async -> ProcessOutcome
}

/// Runs a process with `Foundation.Process`: stdin is `/dev/null`, and stdout and stderr share one
/// pipe. A stop sends `SIGTERM` to the child's process group, or to the child alone if it shares a
/// group, and `SIGKILL` to what is left 2 seconds later.
public final class FoundationProcessRunner: ProcessRunning {
    private let live = LiveProcesses()

    public init() {}

    /// Sends `SIGKILL` now to every process this runner started that is still running, and to the
    /// group of each stopped one whose `SIGKILL` is still pending. For the moment before the app
    /// quits, when nothing will be left to send it later.
    public func killAll() {
        live.killAll()
    }

    public func run(
        executable: URL, arguments: [String], environment: [String: String], timeout: Duration
    ) async -> ProcessOutcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let reader = pipe.fileHandleForReading
        let drain = OutputDrain()
        let box = ProcessBox(live: live)

        let ended: Ended = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                process.terminationHandler = { finished in
                    box.markFinished()
                    let isSignal = finished.terminationReason == .uncaughtSignal
                    continuation.resume(returning: .exited(finished.terminationStatus, bySignal: isSignal))
                }
                switch box.launch(process) {
                case .launched:
                    reader.readabilityHandler = { drain.read($0) }
                    box.startTimeout(timeout)
                    try? pipe.fileHandleForWriting.close()
                case .cancelledEarly:
                    continuation.resume(returning: .cancelledBeforeLaunch)
                case .failed(let message):
                    continuation.resume(returning: .launchFailed(message))
                }
            }
        } onCancel: {
            box.stop(.cancelled)
        }

        switch ended {
        case .cancelledBeforeLaunch:
            drain.close(reader)
            try? pipe.fileHandleForWriting.close()
            return .cancelled
        case .launchFailed(let message):
            drain.close(reader)
            try? pipe.fileHandleForWriting.close()
            return .launchFailed(message)
        case .exited(let status, let bySignal):
            await drain.finish(reader, within: .seconds(1))
            let output = drain.output
            switch box.stopReason {
            case .cancelled: return .cancelled
            case .timedOut: return .timedOut(output: output)
            case nil where bySignal: return .signalled(signal: status, output: output)
            case nil: return .exited(code: status, output: output)
            }
        }
    }
}

private enum Ended {
    /// `status` is the signal's number when `bySignal`, else the exit code.
    case exited(Int32, bySignal: Bool)
    case cancelledBeforeLaunch
    case launchFailed(String)
}

private enum StopReason {
    case cancelled
    case timedOut
}

/// The `Process` and whether it may still be signalled, behind one lock because the cancellation
/// handler and the timeout reach it from other threads. `terminate()` on a process that never ran
/// raises an Objective-C exception Swift can't catch, so a cancel before launch is remembered and
/// the process is never launched.
private final class ProcessBox: @unchecked Sendable {
    enum Launch {
        case launched
        case cancelledEarly
        case failed(String)
    }

    private enum State {
        case notLaunched
        case running(Process)
        case finished
        case cancelledEarly
    }

    private let live: LiveProcesses
    private let lock = NSLock()
    private var state = State.notLaunched
    private var reason: StopReason?
    private var timeoutTask: Task<Void, Never>?
    /// The child's process group, so a stop also reaches the processes it started. `Process`
    /// starts the child leading a group of its own, but doesn't document it, so it is checked at
    /// launch: `nil` when the child shares a group, which isn't the runner's to signal.
    private var groupID: pid_t?

    var stopReason: StopReason? { lock.withLock { reason } }

    init(live: LiveProcesses) {
        self.live = live
    }

    func launch(_ process: Process) -> Launch {
        lock.withLock {
            if case .cancelledEarly = state { return .cancelledEarly }
            do {
                try process.run()
            } catch {
                return .failed("\(process.executableURL?.lastPathComponent ?? "process"): \(error.localizedDescription)")
            }
            state = .running(process)
            let pid = process.processIdentifier
            if getpgid(pid) == pid { groupID = pid }
            live.insert(self)
            return .launched
        }
    }

    func startTimeout(_ timeout: Duration) {
        lock.withLock {
            guard case .running = state else { return }
            timeoutTask = Task { [self] in
                try? await Task.sleep(for: timeout)
                if !Task.isCancelled { stop(.timedOut) }
            }
        }
    }

    func markFinished() {
        lock.withLock {
            state = .finished
            timeoutTask?.cancel()
            if reason == nil || groupID == nil { live.remove(self) }
        }
    }

    func stop(_ stopReason: StopReason) {
        lock.withLock {
            switch state {
            case .notLaunched:
                if stopReason == .cancelled { state = .cancelledEarly }
            case .running(let process):
                if reason == nil {
                    reason = stopReason
                    if let groupID { Darwin.kill(-groupID, SIGTERM) } else { process.terminate() }
                    scheduleKill()
                }
            case .finished, .cancelledEarly:
                break
            }
        }
    }

    private func scheduleKill() {
        Task.detached { [self] in
            try? await Task.sleep(for: .seconds(2))
            killNow()
            live.remove(self)
        }
    }

    /// Sends `SIGKILL` to the child's group even once the child has exited, since a descendant can
    /// outlive it. An emptied group's ID is free for reuse, but pids are handed out in sequence, so
    /// reuse within the 2 seconds would take a wrap of the whole pid space.
    func killNow() {
        lock.withLock {
            if let groupID {
                Darwin.kill(-groupID, SIGKILL)
            } else if case .running(let process) = state, process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}

/// The runner's processes that may still need a `SIGKILL`: from launch until the child exits by
/// itself, or until the `SIGKILL` that follows a stop.
private final class LiveProcesses: Sendable {
    private let boxes = Mutex<[ObjectIdentifier: ProcessBox]>([:])

    func insert(_ box: ProcessBox) {
        boxes.withLock { $0[ObjectIdentifier(box)] = box }
    }

    func remove(_ box: ProcessBox) {
        _ = boxes.withLock { $0.removeValue(forKey: ObjectIdentifier(box)) }
    }

    func killAll() {
        for box in boxes.withLock({ Array($0.values) }) { box.killNow() }
    }
}

/// Collects the last 64 KB of a pipe. One lock covers the `closed` flag, the read and the append,
/// because `availableData` on a closed handle raises an Objective-C exception, and clearing a
/// `readabilityHandler` doesn't stop a call already dispatched.
private final class OutputDrain: @unchecked Sendable {
    private static let keptBytes = 64 * 1024

    private let lock = NSLock()
    private var closed = false
    private var buffer = Data()
    private var waiter: CheckedContinuation<Void, Never>?

    var output: String {
        lock.withLock { String(decoding: buffer, as: UTF8.self) }
    }

    func read(_ handle: FileHandle) {
        lock.withLock {
            if closed { return }
            let data = handle.availableData
            if data.isEmpty {
                closeLocked(handle)
                return
            }
            buffer.append(data)
            if buffer.count > Self.keptBytes {
                buffer = Data(buffer.suffix(Self.keptBytes))
            }
        }
    }

    func close(_ handle: FileHandle) {
        lock.withLock { closeLocked(handle) }
    }

    /// Returns when the pipe reaches end-of-file, or after `deadline` if a descendant still holds
    /// it open; either way the pipe is closed afterwards.
    func finish(_ handle: FileHandle, within deadline: Duration) async {
        let deadlineTask = Task {
            try? await Task.sleep(for: deadline)
            close(handle)
        }
        await withCheckedContinuation { continuation in
            let alreadyClosed = lock.withLock {
                if !closed { waiter = continuation }
                return closed
            }
            if alreadyClosed { continuation.resume() }
        }
        deadlineTask.cancel()
    }

    private func closeLocked(_ handle: FileHandle) {
        if closed { return }
        closed = true
        handle.readabilityHandler = nil
        try? handle.close()
        waiter?.resume()
        waiter = nil
    }
}
