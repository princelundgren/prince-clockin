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
