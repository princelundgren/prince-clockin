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
        invalidationReason: .loggedOut, notifiedForExpiry: at("2026-11-17T17:00:00Z"),
        lastAWSCache: AWSCacheRecord(modified: at("2026-11-17T09:00:05Z"), expiresAt: at("2026-11-17T10:00:00Z")))
    let databricks = Login(displayName: "analytics-dev", kind: .databricksProfile(name: "analytics-dev", accountLevel: true))
    let checked = Login(
        displayName: "analytics-prod", kind: .databricksProfile(name: "analytics-prod", accountLevel: false),
        lastDatabricksCheck: DatabricksCheckRecord(at: at("2026-11-17T09:30:00Z"), result: .couldntCheck),
        lastDatabricksAnswer: DatabricksCheckRecord(at: at("2026-11-17T09:00:00Z"), result: .valid))
    let custom = Login(displayName: "tool", kind: .custom(command: "tool login --host example.cloud.databricks.com"))
    return AppState(
        logins: [aws, databricks, checked, custom],
        presets: [Preset(name: "Morning", loginIDs: [aws.id, databricks.id])],
        settings: Settings(
            notificationLeadTime: 15 * 60, loginTimeout: 120,
            workingHours: WorkingHours(isOn: true, startMinute: 22 * 60, endMinute: 6 * 60, weekdays: [2, 3])))
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

@Test func aLoginWithoutALastAnswerEncodesNoKeyAndDecodes() throws {
    let login = Login(displayName: "analytics-dev", kind: .databricksProfile(name: "analytics-dev", accountLevel: false))

    let json = String(decoding: try JSONEncoder().encode(login), as: UTF8.self)
    let decoded = try JSONDecoder().decode(Login.self, from: Data(json.utf8))

    #expect(!json.contains("lastDatabricksAnswer"))
    #expect(decoded == login)
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

@Test func aStoredSessionLengthUnderAMinuteLoadsAsUnknown() throws {
    try withTemporaryDirectory { directory in
        let store = StateStore(directory: directory)
        let short = Login(displayName: "tool", kind: .custom(command: nil), sessionLength: 36)
        let minute = Login(displayName: "dev", kind: .awsSSOSession(name: "dev"), sessionLength: 60)
        var unknown = short
        unknown.sessionLength = nil

        try store.save(AppState(logins: [short, minute]))

        #expect(store.load() == .loaded(AppState(logins: [unknown, minute])))
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

@Test(arguments: [0, 3])
func aFileOfAnUnknownVersionIsSetAside(version: Int) throws {
    try withTemporaryDirectory { directory in
        let unknown = Data(
            #"{"version": \#(version), "presets": [], "logins": [], "settings": {"notificationLeadTime": 1800, "loginTimeout": 300}}"#.utf8)
        try expectSetAside(unknown, in: directory)
    }
}

/// `state.json` exactly as v1.0.2 wrote it: produced by that release's own `Model.swift` and
/// `StateStore.save`.
private let version1File = """
{
  "logins" : [
    {
      "displayName" : "dev",
      "id" : "00000000-0000-0000-0000-000000000001",
      "invalidatedAt" : "2026-11-17T08:00:00Z",
      "invalidationReason" : "loggedOut",
      "kind" : {
        "name" : "dev",
        "type" : "awsSSOSession"
      },
      "lastAWSCache" : {
        "expiresAt" : "2026-11-17T10:00:00Z",
        "modified" : "2026-11-17T09:00:05Z"
      },
      "loginTime" : "2026-11-17T09:00:00Z",
      "sessionLength" : 28800,
      "warnedForExpiry" : "2026-11-17T17:00:00Z"
    },
    {
      "displayName" : "analytics-dev",
      "id" : "00000000-0000-0000-0000-000000000002",
      "invalidatedAt" : "2026-11-17T08:00:00Z",
      "invalidationReason" : "foundInvalid",
      "kind" : {
        "accountLevel" : true,
        "name" : "analytics-dev",
        "type" : "databricksProfile"
      },
      "lastDatabricksAnswer" : {
        "at" : "2026-11-17T09:00:00Z",
        "result" : "valid"
      },
      "lastDatabricksCheck" : {
        "at" : "2026-11-17T09:30:00Z",
        "result" : "couldntCheck"
      },
      "loginTime" : "2026-11-17T08:30:00Z",
      "sessionLength" : 3600,
      "warnedForExpiry" : "2026-11-17T09:30:00Z"
    },
    {
      "displayName" : "tool",
      "id" : "00000000-0000-0000-0000-000000000003",
      "kind" : {
        "command" : "tool login --host example.cloud.databricks.com",
        "type" : "custom"
      }
    }
  ],
  "presets" : [
    {
      "id" : "00000000-0000-0000-0000-0000000000A1",
      "loginIDs" : [
        "00000000-0000-0000-0000-000000000001",
        "00000000-0000-0000-0000-000000000002"
      ],
      "name" : "Morning"
    }
  ],
  "settings" : {
    "loginTimeout" : 120,
    "warningLeadTime" : 900
  },
  "version" : 1
}
"""

/// The state `version1File` holds.
private func version1State() throws -> AppState {
    let aws = Login(
        id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
        displayName: "dev", kind: .awsSSOSession(name: "dev"), sessionLength: 8 * 3600,
        loginTime: at("2026-11-17T09:00:00Z"), invalidatedAt: at("2026-11-17T08:00:00Z"),
        invalidationReason: .loggedOut, notifiedForExpiry: at("2026-11-17T17:00:00Z"),
        lastAWSCache: AWSCacheRecord(modified: at("2026-11-17T09:00:05Z"), expiresAt: at("2026-11-17T10:00:00Z")))
    let databricks = Login(
        id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002")),
        displayName: "analytics-dev", kind: .databricksProfile(name: "analytics-dev", accountLevel: true),
        sessionLength: 3600, loginTime: at("2026-11-17T08:30:00Z"), invalidatedAt: at("2026-11-17T08:00:00Z"),
        invalidationReason: .foundInvalid, notifiedForExpiry: at("2026-11-17T09:30:00Z"),
        lastDatabricksCheck: DatabricksCheckRecord(at: at("2026-11-17T09:30:00Z"), result: .couldntCheck),
        lastDatabricksAnswer: DatabricksCheckRecord(at: at("2026-11-17T09:00:00Z"), result: .valid))
    let custom = Login(
        id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000003")),
        displayName: "tool", kind: .custom(command: "tool login --host example.cloud.databricks.com"))
    return AppState(
        logins: [aws, databricks, custom],
        presets: [Preset(id: try #require(UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")),
                         name: "Morning", loginIDs: [aws.id, databricks.id])],
        settings: Settings(notificationLeadTime: 15 * 60, loginTimeout: 120))
}

@Test func aVersion1FileLoadsWithEveryFieldAndIsLeftAsItIs() throws {
    try withTemporaryDirectory { directory in
        let file = directory.appending(path: "state.json")
        try Data(version1File.utf8).write(to: file)

        let result = StateStore(directory: directory).load()

        #expect(result == .loaded(try version1State()))
        guard case .loaded(let state) = result else { return }
        #expect(state.version == AppState.currentVersion)
        #expect(state.logins.first?.notifiedForExpiry == at("2026-11-17T17:00:00Z"))
        #expect(state.settings.notificationLeadTime == 15 * 60)
        #expect(String(decoding: try Data(contentsOf: file), as: UTF8.self) == version1File)
    }
}

@Test func aLoadedVersion1FileSavesInTheCurrentFormat() throws {
    try withTemporaryDirectory { directory in
        let store = StateStore(directory: directory)
        try Data(version1File.utf8).write(to: directory.appending(path: "state.json"))
        guard case .loaded(let state) = store.load() else {
            Issue.record("expected .loaded")
            return
        }

        try store.save(state)

        let text = String(decoding: try Data(contentsOf: directory.appending(path: "state.json")), as: UTF8.self)
        #expect(text.contains(#""version" : 2"#))
        #expect(text.contains(#""notifiedForExpiry" : "2026-11-17T17:00:00Z""#))
        #expect(text.contains(#""notificationLeadTime" : 900"#))
        #expect(!text.contains("warned") && !text.contains("warning"))
        #expect(store.load() == .loaded(try version1State()))
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
        #expect(text.contains(#""version" : 2"#))
        #expect(text.contains(#""loginTime" : "2026-11-17T09:00:00Z""#))
        #expect(!text.contains("fingerprint"))
        #expect(text.contains(#""invalidationReason" : "loggedOut""#))
    }
}

@Test func fileWithoutWorkingHoursLoadsWithThemOff() throws {
    try withTemporaryDirectory { directory in
        let json = #"{"version": 2, "presets": [], "logins": [], "settings": {"notificationLeadTime": 1800, "loginTimeout": 300}}"#
        try Data(json.utf8).write(to: directory.appending(path: "state.json"))

        guard case .loaded(let state) = StateStore(directory: directory).load() else {
            Issue.record("expected .loaded")
            return
        }

        #expect(state.settings == Settings(notificationLeadTime: 1800, loginTimeout: 300, workingHours: WorkingHours()))
    }
}

@Test(arguments: [
    (#"{"type": "awsSSOSession", "name": "dev"}"#, true),
    (#"{"type": "databricksProfile", "name": "dev", "accountLevel": false}"#, false),
])
func fileWithoutInvalidationReasonReadsAsTheKindsOnlyOldCause(kind: String, loggedOut: Bool) throws {
    try withTemporaryDirectory { directory in
        let json = """
        {"version": 2, "presets": [], "settings": {"notificationLeadTime": 1800, "loginTimeout": 300},
         "logins": [{"id": "00000000-0000-0000-0000-000000000001", "displayName": "dev",
           "kind": \(kind), "sessionLength": 28800,
           "loginTime": "2026-11-17T09:00:00Z", "invalidatedAt": "2026-11-17T10:00:00Z"}]}
        """
        try Data(json.utf8).write(to: directory.appending(path: "state.json"))

        guard case .loaded(let state) = StateStore(directory: directory).load() else {
            Issue.record("expected .loaded")
            return
        }

        let login = try #require(state.logins.first)
        #expect(login.invalidationReason == nil)
        #expect(isLoggedOut(login) == loggedOut)
        #expect(timerState(for: login, now: at("2026-11-17T11:00:00Z"), leadTime: 0) == .expired)
    }
}

@Test func loadRoundsFractionalValuesDown() throws {
    try withTemporaryDirectory { directory in
        let json = """
        {"version": 2, "presets": [], "settings": {"notificationLeadTime": 1800, "loginTimeout": 300},
         "logins": [{"id": "00000000-0000-0000-0000-000000000001", "displayName": "dev",
           "kind": {"type": "awsSSOSession", "name": "dev"},
           "sessionLength": 28800.5, "loginTime": "2026-11-17T09:00:00.5Z",
           "invalidatedAt": "2026-11-17T08:00:00.9Z", "notifiedForExpiry": "2026-11-17T17:00:00.5Z",
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
        #expect(login.notifiedForExpiry == at("2026-11-17T17:00:00Z"))
        #expect(login.lastAWSCache == AWSCacheRecord(modified: at("2026-11-17T09:00:05Z"), expiresAt: at("2026-11-17T10:00:00Z")))
    }
}

// Fixture assumption: `now` and the length carry a fraction, so the unrounded values differ from
// their stored form. The save and load step is what proves in-memory equals on-disk.
@Test func setTimerWithFractionalTimesSurvivesStore() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000.7)
    let dev = Login(displayName: "dev", kind: .awsSSOSession(name: "dev"))
    var model = LoginsModel(state: AppState(logins: [dev]))
    try model.setTimer(id: dev.id, .expiresIn(9_999.6, sessionLength: 8 * 3600 + 0.4), now: now)
    let before = try #require(model.state.logins.first.flatMap(expiry(of:)))

    try withTemporaryDirectory { directory in
        let store = StateStore(directory: directory)
        try store.save(model.state)
        guard case .loaded(let loaded) = store.load() else {
            Issue.record("expected .loaded")
            return
        }
        #expect(loaded.logins.first.flatMap(expiry(of:)) == before)
    }
}

@Test func stillValidSurvivesSaveAndLoad() throws {
    let now = at("2026-11-17T12:00:00Z")
    let prod = Login(
        displayName: "analytics-dev", kind: .databricksProfile(name: "analytics-dev", accountLevel: false),
        sessionLength: 3600, loginTime: now.addingTimeInterval(-7200))
    var model = LoginsModel(state: AppState(logins: [prod]))
    model.apply(.valid, login: prod.id, now: now)

    try withTemporaryDirectory { directory in
        let store = StateStore(directory: directory)
        try store.save(model.state)
        guard case .loaded(let loaded) = store.load() else {
            Issue.record("expected .loaded")
            return
        }
        let login = try #require(loaded.logins.first)
        #expect(isStillValid(login, now: now))
    }
}
