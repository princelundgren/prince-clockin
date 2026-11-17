import Foundation
import Testing
import PrinceClockInCore

/// A fresh, empty directory that is removed when the test ends.
private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let directory = FileManager.default.temporaryDirectory.appending(path: "PrinceClockInTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}

private func sampleState() -> AppState {
    let aws = Login(
        displayName: "dev", kind: .awsSSOSession(name: "dev"), sessionLength: 8 * 3600,
        loginTime: at("2026-11-17T09:00:00Z"), invalidatedAt: at("2026-11-17T08:00:00Z"),
        warnedForExpiry: at("2026-11-17T17:00:00Z"),
        lastAWSCache: AWSCacheRecord(modified: at("2026-11-17T09:00:05Z"), expiresAt: at("2026-11-17T10:00:00Z")))
    let databricks = Login(displayName: "analytics-dev", kind: .databricksProfile(name: "analytics-dev", accountLevel: true))
    let custom = Login(displayName: "tool", kind: .custom(command: "tool login --host example.cloud.databricks.com"))
    return AppState(
        logins: [aws, databricks, custom],
        presets: [Preset(name: "Morning", loginIDs: [aws.id, databricks.id])],
        settings: Settings(warningLeadTime: 15 * 60, loginTimeout: 120))
}

private func encodeFlat(_ kind: LoginKind) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(kind), as: UTF8.self)
}

@Test func loginKindEncodesFlat() throws {
    #expect(try encodeFlat(.awsSSOSession(name: "dev")) == #"{"name":"dev","type":"awsSSOSession"}"#)
    #expect(try encodeFlat(.databricksProfile(name: "analytics-dev", accountLevel: false))
            == #"{"accountLevel":false,"name":"analytics-dev","type":"databricksProfile"}"#)
    #expect(try encodeFlat(.custom(command: "tool login")) == #"{"command":"tool login","type":"custom"}"#)
    #expect(try encodeFlat(.custom(command: nil)) == #"{"type":"custom"}"#)
}

@Test func awsDefaultsToEightHoursDatabricksToNil() {
    let eightHours: TimeInterval = 8 * 3600
    #expect(Login.defaultSessionLength(for: .awsSSOSession(name: "dev")) == eightHours)
    #expect(Login.defaultSessionLength(for: .databricksProfile(name: "analytics-dev", accountLevel: false)) == nil)
    #expect(Login.defaultSessionLength(for: .custom(command: nil)) == nil)
}

@Test func loginKindDecodesItsFlatShape() throws {
    let json = #"{"type":"databricksProfile","name":"analytics-dev","accountLevel":false}"#

    let kind = try JSONDecoder().decode(LoginKind.self, from: Data(json.utf8))

    #expect(kind == .databricksProfile(name: "analytics-dev", accountLevel: false))
}

@Test func storeRoundTripsState() throws {
    try withTemporaryDirectory { directory in
        let store = StateStore(directory: directory)
        let state = sampleState()

        try store.save(state)

        #expect(store.load() == .loaded(state))
    }
}

@Test func saveCreatesMissingDirectory() throws {
    try withTemporaryDirectory { directory in
        let store = StateStore(directory: directory.appending(path: "nested/PrinceClockIn"))

        try store.save(AppState())

        #expect(store.load() == .loaded(AppState()))
    }
}

@Test func saveStoresFractionalAssignmentsAsWholeSeconds() throws {
    try withTemporaryDirectory { directory in
        let store = StateStore(directory: directory)
        var login = Login(displayName: "dev", kind: .awsSSOSession(name: "dev"))
        // Assigned directly, bypassing the rounding in `Login.init`.
        login.loginTime = Date(timeIntervalSince1970: 1_800_000_000.7)
        login.sessionLength = 28800.9
        let rounded = Login(id: login.id, displayName: "dev", kind: login.kind,
                            sessionLength: 28800, loginTime: Date(timeIntervalSince1970: 1_800_000_000))

        try store.save(AppState(logins: [login]))

        // `load` rounds too, so the file itself is checked: the fix is that `save` writes whole seconds.
        let text = String(decoding: try Data(contentsOf: directory.appending(path: "state.json")), as: UTF8.self)
        #expect(text.contains(#""sessionLength" : 28800"#) && !text.contains("28800."))
        #expect(store.load() == .loaded(AppState(logins: [rounded])))
    }
}

@Test func missingFileLoadsEmpty() throws {
    try withTemporaryDirectory { directory in
        #expect(StateStore(directory: directory).load() == .empty)
    }
}

private func expectSetAside(_ original: Data, in directory: URL) throws {
    try original.write(to: directory.appending(path: "state.json"))

    let result = StateStore(directory: directory).load()

    guard case .setAside(let backup) = result else {
        Issue.record("expected .setAside, got \(result)")
        return
    }
    #expect(backup.lastPathComponent.wholeMatch(of: /state-\d{8}-\d{6}-[0-9a-f]{4}\.json\.bak/) != nil)
    #expect(try Data(contentsOf: backup) == original)
    #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "state.json").path))
}

@Test func corruptFileIsSetAsideAndLoadsEmpty() throws {
    try withTemporaryDirectory { directory in
        try expectSetAside(Data("{ not json".utf8), in: directory)
        #expect(StateStore(directory: directory).load() == .empty)
    }
}

@Test func emptyFileIsSetAside() throws {
    try withTemporaryDirectory { directory in
        try expectSetAside(Data(), in: directory)
    }
}

@Test func newerVersionIsSetAside() throws {
    try withTemporaryDirectory { directory in
        let newer = Data(#"{"version": 2, "somethingNew": [1, 2, 3]}"#.utf8)
        try expectSetAside(newer, in: directory)
    }
}

@Test func setAsideNeverOverwritesAnEarlierBackup() throws {
    try withTemporaryDirectory { directory in
        let store = StateStore(directory: directory)
        var backups: [URL] = []

        for text in ["first", "second"] {
            try Data(text.utf8).write(to: directory.appending(path: "state.json"))
            guard case .setAside(let backup) = store.load() else {
                Issue.record("expected .setAside")
                return
            }
            backups.append(backup)
        }

        #expect(Set(backups).count == 2)
        #expect(try backups.map { String(decoding: try Data(contentsOf: $0), as: UTF8.self) } == ["first", "second"])
    }
}

@Test func storedJSONIsReadable() throws {
    try withTemporaryDirectory { directory in
        try StateStore(directory: directory).save(sampleState())

        let text = String(decoding: try Data(contentsOf: directory.appending(path: "state.json")), as: UTF8.self)

        #expect(text.contains(#""sessionLength" : 28800"#))
        #expect(text.contains(#""version" : 1"#))
        #expect(text.contains(#""loginTime" : "2026-11-17T09:00:00Z""#))
        #expect(!text.contains("fingerprint"))
    }
}

@Test func loadRoundsFractionalValuesDown() throws {
    try withTemporaryDirectory { directory in
        let json = """
        {"version": 1, "presets": [], "settings": {"warningLeadTime": 1800, "loginTimeout": 300},
         "logins": [{"id": "00000000-0000-0000-0000-000000000001", "displayName": "dev",
           "kind": {"type": "awsSSOSession", "name": "dev"},
           "sessionLength": 28800.5, "loginTime": "2026-11-17T09:00:00.5Z",
           "invalidatedAt": "2026-11-17T08:00:00.9Z", "warnedForExpiry": "2026-11-17T17:00:00.5Z",
           "lastAWSCache": {"modified": "2026-11-17T09:00:05.5Z", "expiresAt": "2026-11-17T10:00:00.5Z"}}]}
        """
        try Data(json.utf8).write(to: directory.appending(path: "state.json"))

        guard case .loaded(let state) = StateStore(directory: directory).load() else {
            Issue.record("expected .loaded")
            return
        }

        let login = try #require(state.logins.first)
        #expect(login.sessionLength == 28800)
        #expect(login.loginTime == at("2026-11-17T09:00:00Z"))
        #expect(login.invalidatedAt == at("2026-11-17T08:00:00Z"))
        #expect(login.warnedForExpiry == at("2026-11-17T17:00:00Z"))
        #expect(login.lastAWSCache == AWSCacheRecord(modified: at("2026-11-17T09:00:05Z"), expiresAt: at("2026-11-17T10:00:00Z")))
    }
}
