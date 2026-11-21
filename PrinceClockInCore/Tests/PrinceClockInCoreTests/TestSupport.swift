import Foundation
import PrinceClockInCore
import SQLite3

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

/// What a login shell prints when asked for `PATH`, with rc-file noise around the markers.
func pathOutput(_ path: String) -> ProcessOutcome {
    .exited(code: 0, output: "Welcome!\n__PCI_PATH__\(path)__PCI_END__\nbye")
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
    /// Whether the run asked for its stdout to be discarded.
    var discardsStandardOutput = false
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
        await record(RecordedCall(executable: executable, arguments: arguments, environment: environment, timeout: timeout))
    }

    func runDiscardingStandardOutput(
        executable: URL, arguments: [String], environment: [String: String], timeout: Duration
    ) async -> ProcessOutcome {
        await record(RecordedCall(
            executable: executable, arguments: arguments, environment: environment, timeout: timeout,
            discardsStandardOutput: true))
    }

    private func record(_ call: RecordedCall) async -> ProcessOutcome {
        let index = lock.withLock {
            recorded.append(call)
            return recorded.count - 1
        }
        return await respond(index)
    }
}

/// A gcloud `credentials.db` at `url`, with gcloud's schema, to which statements are applied as
/// gcloud applies them. `value` holds a placeholder, never a real token.
final class GcloudStoreFixture {
    let url: URL
    private var database: OpaquePointer?

    init(at url: URL) throws {
        self.url = url
        guard sqlite3_open(url.path, &database) == SQLITE_OK else { throw FixtureError.sqlite("open") }
        try execute("CREATE TABLE IF NOT EXISTS credentials (account_id TEXT PRIMARY KEY, value BLOB)")
    }

    deinit { sqlite3_close(database) }

    /// gcloud's write at a login: `REPLACE INTO`, which gives the row a new, larger `rowid`.
    func replace(_ account: String) throws {
        try execute("REPLACE INTO credentials (account_id, value) VALUES ('\(account)', 'placeholder')")
    }

    /// gcloud's write at `gcloud auth revoke`.
    func delete(_ account: String) throws {
        try execute("DELETE FROM credentials WHERE account_id = '\(account)'")
    }

    func rowID(of account: String) throws -> Int64? {
        try readGcloudCredentials(at: url).rowIDs[account]
    }

    /// Fixture SQL only: the accounts are test constants, so they are interpolated.
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw FixtureError.sqlite(sql) }
    }

    enum FixtureError: Error {
        case sqlite(String)
    }
}

/// The OCI CLI's config as a test sets it: no file until `set`, and unreadable after `fail`.
final class FakeOCIReader: OCIConfigReading, @unchecked Sendable {
    static let configFile = URL(filePath: "/Users/someone/.oci/config")

    private let lock = NSLock()
    private var config: OCIConfig? = OCIConfig(file: FakeOCIReader.configFile, profiles: [], publicKeys: [:])

    init() {}

    init(_ profiles: [OCISessionProfile], publicKeys: [String: OCIKeyFileState] = [:]) {
        set(profiles, publicKeys: publicKeys)
    }

    func set(_ profiles: [OCISessionProfile], publicKeys: [String: OCIKeyFileState] = [:]) {
        lock.withLock { config = OCIConfig(file: Self.configFile, profiles: profiles, publicKeys: publicKeys) }
    }

    func fail() { lock.withLock { config = nil } }

    func read() -> OCIConfig? { lock.withLock { config } }
}

/// A session profile as `oci session authenticate` writes it, its session in
/// `~/.oci/sessions/<name>` of `/Users/someone`.
func ociProfile(_ name: String, region: String? = "eu-frankfurt-1") -> OCISessionProfile {
    OCISessionProfile(
        name: name, region: region, securityTokenFile: URL(filePath: "/Users/someone/.oci/sessions/\(name)/token"))
}
