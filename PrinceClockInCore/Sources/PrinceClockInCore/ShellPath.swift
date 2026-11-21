import Foundation

/// The directories to search for the CLIs. `fromShell` is false when they are the standard
/// fallback, because the shell wasn't read or the read failed.
public struct ResolvedPath: Equatable, Sendable {
    public let directories: [URL]
    public let fromShell: Bool

    public init(directories: [URL], fromShell: Bool) {
        self.directories = directories
        self.fromShell = fromShell
    }

    /// The first executable file called `name` in `directories`.
    public func locate(_ name: String) -> URL? {
        for directory in directories {
            let candidate = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: candidate.path)
            {
                return candidate
            }
        }
        return nil
    }

    /// `base` with `PATH` replaced by `directories`.
    public func childEnvironment(base: [String: String]) -> [String: String] {
        var child = base
        child["PATH"] = directories.map(\.path).joined(separator: ":")
        return child
    }
}

/// Finds the directories to search for the CLIs.
public protocol PathResolving: Sendable {
    /// The directories to search; each call may read them again, so a caller that needs them twice
    /// keeps the first answer.
    func resolvePath() async -> ResolvedPath
}

/// Reads `PATH` from the user's login shell, since a GUI app doesn't inherit it (Homebrew, mise).
/// Empty and relative entries are dropped, since they would resolve against the app's working
/// directory. Only `zsh` and `bash` are read; any other shell gets the standard `PATH`. Only a
/// successful read is kept, so a failed one is tried again on the next call.
public actor ShellPathResolver: PathResolving {
    private static let startMarker = "__PCI_PATH__"
    private static let endMarker = "__PCI_END__"
    private static let readTimeout = Duration.seconds(5)
    private static let fallback = ResolvedPath(
        directories: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            .map { URL(fileURLWithPath: $0) },
        fromShell: false)

    private let runner: ProcessRunning
    private let shell: URL
    private let environment: [String: String]
    private var cached: ResolvedPath?
    private var inFlight: Task<[URL]?, Never>?

    public init(runner: ProcessRunning, shell: URL, environment: [String: String]) {
        self.runner = runner
        self.shell = shell
        self.environment = environment
    }

    public func resolvePath() async -> ResolvedPath {
        if let cached { return cached }
        guard ["zsh", "bash"].contains(shell.lastPathComponent) else { return Self.fallback }
        let read: Task<[URL]?, Never>
        if let inFlight {
            read = inFlight
        } else {
            read = Task { [runner, shell, environment] in
                await Self.readDirectories(runner: runner, shell: shell, environment: environment)
            }
            inFlight = read
        }
        let directories = await read.value
        if inFlight == read { inFlight = nil }
        guard let directories else { return Self.fallback }
        let resolved = ResolvedPath(directories: directories, fromShell: true)
        cached = resolved
        return resolved
    }

    /// The first executable file called `name` on the resolved `PATH`.
    public func locate(_ name: String) async -> URL? {
        await resolvePath().locate(name)
    }

    /// `base` with `PATH` replaced by the resolved one.
    public func childEnvironment(base: [String: String]) async -> [String: String] {
        await resolvePath().childEnvironment(base: base)
    }

    private static func readDirectories(
        runner: ProcessRunning, shell: URL, environment: [String: String]
    ) async -> [URL]? {
        let script = #"printf '\n__PCI_PATH__%s__PCI_END__\n' "$PATH""#
        let outcome = await runner.run(
            executable: shell, arguments: ["-i", "-l", "-c", script],
            environment: environment, timeout: readTimeout)
        guard case .exited(_, let output) = outcome,
            let start = output.range(of: startMarker),
            let end = output.range(of: endMarker, range: start.upperBound..<output.endIndex)
        else { return nil }
        let directories = output[start.upperBound..<end.lowerBound]
            .split(separator: ":", omittingEmptySubsequences: true)
            .filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: String($0)) }
        return directories.isEmpty ? nil : directories
    }
}
