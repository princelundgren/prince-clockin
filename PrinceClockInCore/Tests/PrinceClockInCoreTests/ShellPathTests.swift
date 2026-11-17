import Foundation
import Testing
import PrinceClockInCore

private let zsh = URL(fileURLWithPath: "/bin/zsh")
private let fallbackDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

@Suite struct ShellPathTests {
    @Test func pathResolverIgnoresRcNoise() async {
        let runner = FakeRunner { _ in pathOutput("/opt/homebrew/bin:/usr/bin") }
        let resolver = ShellPathResolver(runner: runner, shell: zsh, environment: ["HOME": "/h"])
        let path = await resolver.resolvePath()
        #expect(path == ResolvedPath(
            directories: [URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/bin")],
            fromShell: true))
        let call = runner.calls[0]
        #expect(call.executable == zsh)
        #expect(call.arguments.prefix(3) == ["-i", "-l", "-c"])
        #expect(call.environment == ["HOME": "/h"])
        #expect(call.timeout == .seconds(5))
    }

    @Test func pathResolverRunsShellOnce() async {
        let runner = FakeRunner { _ in pathOutput("/usr/bin") }
        let resolver = ShellPathResolver(runner: runner, shell: zsh, environment: [:])
        _ = await resolver.resolvePath()
        _ = await resolver.resolvePath()
        #expect(runner.calls.count == 1)
    }

    @Test func concurrentCallsShareOneRead() async throws {
        let gate = Gate()
        let runner = FakeRunner { _ in
            await gate.wait()
            return pathOutput("/usr/bin")
        }
        let resolver = ShellPathResolver(runner: runner, shell: zsh, environment: [:])
        let first = Task { await resolver.resolvePath() }
        let second = Task { await resolver.resolvePath() }
        // Timing assumption: the second call must arrive while the read is running. Opening the gate
        // earlier would let it hit the cache and pass even with the de-duplication broken.
        try await Task.sleep(for: .milliseconds(200))
        await gate.open()
        let firstPath = await first.value
        let secondPath = await second.value
        #expect(firstPath == secondPath)
        #expect(runner.calls.count == 1)
    }

    @Test func pathResolverFallsBackOnTimeoutAndRetries() async {
        let runner = FakeRunner { index in
            index == 0 ? .timedOut(output: "") : pathOutput("/usr/bin")
        }
        let resolver = ShellPathResolver(runner: runner, shell: zsh, environment: [:])
        let failed = await resolver.resolvePath()
        #expect(failed.fromShell == false)
        #expect(failed.directories.map(\.path) == fallbackDirectories)
        let retried = await resolver.resolvePath()
        #expect(retried.fromShell == true)
        #expect(runner.calls.count == 2)
    }

    @Test func emptyReadFallsBack() async {
        let runner = FakeRunner { _ in pathOutput("") }
        let resolver = ShellPathResolver(runner: runner, shell: zsh, environment: [:])
        #expect(await resolver.resolvePath().fromShell == false)
    }

    @Test func otherShellUsesFallbackWithoutRunning() async {
        let runner = FakeRunner { _ in pathOutput("/usr/bin") }
        let resolver = ShellPathResolver(
            runner: runner, shell: URL(fileURLWithPath: "/usr/local/bin/fish"), environment: [:])
        let path = await resolver.resolvePath()
        #expect(path.fromShell == false)
        #expect(path.directories.map(\.path) == fallbackDirectories)
        #expect(runner.calls.isEmpty)
    }

    @Test func locateSkipsRelativeEntries() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeExecutable(named: "tool", in: directory)
        let runner = FakeRunner { _ in pathOutput(":relative/dir::\(directory.path)") }
        let resolver = ShellPathResolver(runner: runner, shell: zsh, environment: [:])
        #expect(await resolver.locate("tool") == directory.appendingPathComponent("tool"))
        #expect(await resolver.resolvePath().directories == [directory])
    }

    @Test func locateReturnsNilWhenMissing() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeExecutable(named: "tool", in: directory)
        let runner = FakeRunner { _ in pathOutput(directory.path) }
        let resolver = ShellPathResolver(runner: runner, shell: zsh, environment: [:])
        #expect(await resolver.locate("other") == nil)
    }

    @Test func childEnvironmentReplacesOnlyPath() async {
        let runner = FakeRunner { _ in pathOutput("/a:/b") }
        let resolver = ShellPathResolver(runner: runner, shell: zsh, environment: [:])
        let environment = await resolver.childEnvironment(base: ["PATH": "/old", "HOME": "/h"])
        #expect(environment == ["PATH": "/a:/b", "HOME": "/h"])
    }

    @Test func realZshReadsRcFile() async throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let marker = home.appendingPathComponent("marker-bin").path
        try "echo rc-noise\nexport PATH=\"\(marker):$PATH\"\n"
            .write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let environment = ["ZDOTDIR": home.path, "HOME": home.path, "PATH": "/usr/bin:/bin"]
        let resolver = ShellPathResolver(runner: FoundationProcessRunner(), shell: zsh, environment: environment)
        let path = await resolver.resolvePath()
        #expect(path.fromShell == true)
        #expect(path.directories.first?.path == marker)
    }
}
