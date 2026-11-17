import Foundation
import PrinceClockInCore

/// Parses an ISO 8601 fixture such as `2026-11-17T09:00:00Z`; a malformed fixture fails the test run.
func at(_ iso: String) -> Date {
    guard let date = try? Date(iso, strategy: .iso8601) else {
        preconditionFailure("bad fixture date \(iso)")
    }
    return date
}

/// A login whose timer ends `remaining` seconds after `now`, with an 8 hour session.
func login(remaining: TimeInterval, now: Date, name: String = "dev") -> Login {
    let length: TimeInterval = 8 * 3600
    return Login(
        displayName: name, kind: .awsSSOSession(name: name), sessionLength: length,
        loginTime: now.addingTimeInterval(remaining - length))
}

func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pci-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

func makeExecutable(named name: String, in directory: URL) throws {
    let file = directory.appendingPathComponent(name)
    try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
}

/// Holds a test's async step until the test opens it.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

struct RecordedCall {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let timeout: Duration
}

final class FakeRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RecordedCall] = []
    private let respond: @Sendable (Int) async -> ProcessOutcome

    /// `respond` gets the zero-based index of each call.
    init(respond: @escaping @Sendable (Int) async -> ProcessOutcome) {
        self.respond = respond
    }

    var calls: [RecordedCall] {
        lock.withLock { recorded }
    }

    func run(
        executable: URL, arguments: [String], environment: [String: String], timeout: Duration
    ) async -> ProcessOutcome {
        let index = lock.withLock {
            recorded.append(RecordedCall(
                executable: executable, arguments: arguments, environment: environment, timeout: timeout))
            return recorded.count - 1
        }
        return await respond(index)
    }
}
