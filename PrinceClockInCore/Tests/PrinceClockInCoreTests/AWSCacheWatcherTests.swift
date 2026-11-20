import Foundation
import Testing
import PrinceClockInCore

/// These run real File System Events streams, which report about a second after each change, and
/// also report a change made just before a stream started. So each test lets its setup's reports
/// pass before the change under test, then waits for that change's report with a generous timeout.
@MainActor
@Suite struct AWSCacheWatcherTests {
    private final class Calls {
        var count = 0
    }

    private func eventually(within timeout: Duration, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    /// Longer than the watcher's one-second latency, so every report of the setup has arrived.
    private func letSetupReportsPass() async throws {
        try await Task.sleep(for: .seconds(3))
    }

    /// Rewrites the file as the AWS CLI does: opened for writing, truncated, written, with no rename.
    private func rewriteInPlace(_ file: URL, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    @Test func reportsAFileRewrittenInPlace() async throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appending(path: "session.json")
        try Data("{}".utf8).write(to: file)
        let calls = Calls()
        let watcher = AWSCacheWatcher(directory: directory) { calls.count += 1 }
        try await letSetupReportsPass()
        let beforeRewrite = calls.count

        try rewriteInPlace(file, #"{"expiresAt":"later"}"#)

        #expect(await eventually(within: .seconds(10)) { calls.count > beforeRewrite })
        withExtendedLifetime(watcher) {}
    }

    @Test func reportsChangesInADirectoryCreatedAfterItStarted() async throws {
        let directory = try makeTemporaryDirectory().appending(path: "sso/cache")
        let calls = Calls()
        let watcher = AWSCacheWatcher(directory: directory) { calls.count += 1 }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "session.json")
        try Data("{}".utf8).write(to: file)
        #expect(await eventually(within: .seconds(10)) { calls.count > 0 })
        try await letSetupReportsPass()
        let beforeRewrite = calls.count

        try rewriteInPlace(file, #"{"expiresAt":"later"}"#)

        #expect(await eventually(within: .seconds(10)) { calls.count > beforeRewrite })
        withExtendedLifetime(watcher) {}
    }
}
