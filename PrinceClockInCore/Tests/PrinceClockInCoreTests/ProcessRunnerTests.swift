import Foundation
import Testing
import PrinceClockInCore

@Suite struct ProcessRunnerTests {
    private func run(_ executable: String, _ arguments: [String], timeout: Duration = .seconds(10)) async -> ProcessOutcome {
        await FoundationProcessRunner().run(
            executable: URL(fileURLWithPath: executable), arguments: arguments,
            environment: ["PATH": "/usr/bin:/bin"], timeout: timeout)
    }

    @Test func cancelBeforeLaunchReturnsCancelledWithoutCrash() async {
        let gate = Gate()
        let task = Task {
            await gate.wait()
            return await run("/bin/sleep", ["30"])
        }
        task.cancel()
        await gate.open()
        #expect(await task.value == .cancelled)
    }

    @Test func runnerTerminatesChildOnCancel() async throws {
        let started = ContinuousClock.now
        let task = Task { await run("/bin/sleep", ["30"]) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        #expect(await task.value == .cancelled)
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test func runnerTimesOut() async {
        let outcome = await run("/bin/sleep", ["30"], timeout: .seconds(1))
        guard case .timedOut = outcome else {
            Issue.record("expected timedOut, got \(outcome)")
            return
        }
    }

    @Test func runnerReportsExitCodeAndOutput() async {
        let outcome = await run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"])
        guard case .exited(let code, let output) = outcome else {
            Issue.record("expected exited, got \(outcome)")
            return
        }
        #expect(code == 3)
        #expect(output.contains("out") && output.contains("err"))
    }

    @Test func runnerCanDiscardStandardOutputAndKeepStandardError() async {
        let outcome = await FoundationProcessRunner().runDiscardingStandardOutput(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo secret-out; echo err >&2; exit 3"],
            environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(10))

        #expect(outcome == .exited(code: 3, output: "err\n"))
    }

    @Test func runnerReportsASignalApartFromAnExitCode() async {
        let outcome = await run("/bin/sh", ["-c", "echo before; kill -9 $$"])
        #expect(outcome == .signalled(signal: 9, output: "before\n"))
    }

    @Test func runnerReportsLaunchFailure() async {
        let outcome = await run("/nonexistent/tool", [])
        guard case .launchFailed = outcome else {
            Issue.record("expected launchFailed, got \(outcome)")
            return
        }
    }

    // Swaps fd 0 of the whole test process for a pipe nobody writes to, so a child that inherited
    // stdin would block. No other test reads stdin (the others set their children's stdin or never
    // read it), so running beside them is safe.
    @Test func runnerGivesChildNoStandardInput() async throws {
        var fds: [Int32] = [0, 0]
        try #require(pipe(&fds) == 0)
        let savedStdin = dup(0)
        try #require(savedStdin >= 0)
        dup2(fds[0], 0)
        defer {
            dup2(savedStdin, 0)
            close(savedStdin)
            close(fds[0])
            close(fds[1])
        }
        let outcome = await run("/bin/cat", [], timeout: .seconds(2))
        #expect(outcome == .exited(code: 0, output: ""))
    }

    @Test func runnerKillsChildThatIgnoresTerminate() async {
        // The ignored signal survives the exec, so only SIGKILL ends the sleep.
        let started = ContinuousClock.now
        let outcome = await run(
            "/bin/sh", ["-c", #"trap "" TERM; exec /bin/sleep 30"#], timeout: .seconds(1))
        guard case .timedOut = outcome else {
            Issue.record("expected timedOut, got \(outcome)")
            return
        }
        #expect(ContinuousClock.now - started < .seconds(6))
    }

    /// Runs `script` under `sh` with a file for it to write a pid to, until the 1-second timeout,
    /// and returns the outcome and that pid.
    private func runForking(_ script: String) async throws -> (ProcessOutcome, pid_t) {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("grandchild")
        let outcome = await run("/bin/sh", ["-c", script, "sh", pidFile.path], timeout: .seconds(1))
        let text = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        return (outcome, pid)
    }

    /// Whether `pid` is gone within `deadline`, polled since launchd reaps an orphan shortly after
    /// it dies. Kills it on the way out, so a failing test leaves nothing running.
    private func isGone(_ pid: pid_t, within deadline: Duration) async -> Bool {
        let end = ContinuousClock.now + deadline
        while ContinuousClock.now < end {
            if kill(pid, 0) == -1 && errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        kill(pid, SIGKILL)
        return false
    }

    @Test func aTimeoutEndsWhatTheChildStarted() async throws {
        let (outcome, grandchild) = try await runForking(#"sleep 30 & echo $! > "$1"; wait"#)
        guard case .timedOut = outcome else {
            Issue.record("expected timedOut, got \(outcome)")
            return
        }
        #expect(await isGone(grandchild, within: .seconds(2)))
    }

    @Test func aTimeoutKillsADescendantThatIgnoresTerminate() async throws {
        let (outcome, grandchild) = try await runForking(
            #"(trap "" TERM; exec sleep 30) & echo $! > "$1"; wait"#)
        guard case .timedOut = outcome else {
            Issue.record("expected timedOut, got \(outcome)")
            return
        }
        #expect(await isGone(grandchild, within: .seconds(4)))
    }

    @Test func killAllEndsARunningChildAndWhatItStarted() async throws {
        let runner = FoundationProcessRunner()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("grandchild")
        let task = Task {
            await runner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", #"sleep 30 & echo $! > "$1"; wait"#, "sh", pidFile.path],
                environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(30))
        }
        let grandchild = try await waitForPid(in: pidFile)

        runner.killAll()

        #expect(await task.value == .signalled(signal: SIGKILL, output: ""))
        #expect(await isGone(grandchild, within: .seconds(1)))
    }

    @Test func killAllDoesntWaitForAStoppedGroupsPendingKill() async throws {
        let runner = FoundationProcessRunner()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("grandchild")
        let task = Task {
            await runner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", #"(trap "" TERM; exec sleep 30) & echo $! > "$1"; wait"#, "sh", pidFile.path],
                environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(30))
        }
        let grandchild = try await waitForPid(in: pidFile)
        task.cancel()
        #expect(await task.value == .cancelled)

        runner.killAll()

        // Well inside the 2 seconds after which the stop's own SIGKILL would have come.
        #expect(await isGone(grandchild, within: .milliseconds(500)))
    }

    /// The pid a script writes to `file`, once it has.
    private func waitForPid(in file: URL) async throws -> pid_t {
        for _ in 0..<100 {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try #require(nil as pid_t?, "no pid written to \(file.lastPathComponent)")
    }

    @Test func runnerDrainsLargeOutput() async {
        let script = "i=0; while [ $i -lt 1024 ]; do printf '%01023d\\n' $i >&2; i=$((i+1)); done"
        let outcome = await run("/bin/sh", ["-c", script])
        guard case .exited(let code, let output) = outcome else {
            Issue.record("expected exited, got \(outcome)")
            return
        }
        #expect(code == 0)
        #expect(output.utf8.count == 64 * 1024)
        #expect(output.hasSuffix("1023\n"))
    }

    @Test func runnerReturnsWhenChildExitsThoughDescendantHoldsPipe() async {
        let started = ContinuousClock.now
        let outcome = await run("/bin/sh", ["-c", "sleep 5 & echo done"])
        #expect(outcome == .exited(code: 0, output: "done\n"))
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test func runnerReturnsWhenDescendantKeepsWriting() async {
        // The writer normally ends on SIGPIPE once the runner closes the pipe; the loop bound is a backstop.
        let script = "(i=0; while [ $i -lt 1000 ]; do echo x; sleep 0.005; i=$((i+1)); done) & echo done"
        let started = ContinuousClock.now
        let outcome = await run("/bin/sh", ["-c", script])
        guard case .exited(let code, let output) = outcome else {
            Issue.record("expected exited, got \(outcome)")
            return
        }
        #expect(code == 0)
        #expect(output.contains("done\n"))
        #expect(ContinuousClock.now - started < .seconds(3))
    }
}
