import Foundation
import Testing
import PrinceClockInCore

private let secretFixture = "fixture-token-not-a-real-secret"

private func cacheJSON(expiresAt: String = "2026-11-17T10:00:00Z", refreshToken: String = "refresh-a") -> String {
    """
    {"accessToken":"\(secretFixture)-access","clientId":"\(secretFixture)-id",
     "clientSecret":"\(secretFixture)-secret","refreshToken":"\(refreshToken)","expiresAt":"\(expiresAt)",
     "region":"eu-north-1","startUrl":"https://example.awsapps.com/start"}
    """
}

/// Writes `json` to a new cache file whose modification date is `modified`.
private func writeCacheFile(_ json: String, modified: Date, in directory: URL) throws -> URL {
    let file = directory.appendingPathComponent("cache.json")
    try json.write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
    return file
}

private func hash(_ byte: UInt8) -> Data { Data(repeating: byte, count: 32) }

private func present(
    _ modified: String, expires: String = "2026-11-17T10:00:00Z", hash byte: UInt8? = nil
) -> AWSCacheState {
    .present(AWSCacheSnapshot(modified: at(modified), expiresAt: at(expires), refreshTokenHash: byte.map(hash)))
}

private let lead: TimeInterval = 30 * 60

@Suite struct AWSCacheFileTests {
    @Test func cacheFileNameIsSHA1OfSessionName() {
        let directory = URL(fileURLWithPath: "/cache")
        // `printf dev | shasum`
        #expect(awsCacheFile(forSession: "dev", cacheDirectory: directory).path
            == "/cache/34c6fceca75e456f25e7e99531e2425c6c1de443.json")
    }

    @Test func snapshotIgnoresOtherFields() throws {
        let directory = try makeTemporaryDirectory()
        let file = try writeCacheFile(cacheJSON(), modified: at("2026-11-17T09:00:00Z"), in: directory)
        let state = try readCacheState(at: file, previous: .unread)
        guard case .present(let snapshot) = state else { Issue.record("not present"); return }
        #expect(snapshot.expiresAt == at("2026-11-17T10:00:00Z"))
        #expect(snapshot.modified == at("2026-11-17T09:00:00Z"))
        #expect(!String(describing: snapshot).contains(secretFixture))
        #expect(!String(describing: snapshot).contains("refresh-a"))
    }

    @Test func corruptCacheErrorOmitsContents() throws {
        let directory = try makeTemporaryDirectory()
        let file = try writeCacheFile(
            "{\"refreshToken\": \"\(secretFixture)\" oops", modified: at("2026-11-17T09:00:00Z"), in: directory)
        do {
            _ = try readCacheState(at: file, previous: .unread)
            Issue.record("expected a throw")
        } catch {
            #expect(error as? AWSCacheError == AWSCacheError(fileName: "cache.json"))
            #expect(!String(describing: error).contains(secretFixture))
            #expect(!error.localizedDescription.contains(secretFixture))
            #expect(!String(describing: Mirror(reflecting: error)).contains(secretFixture))
        }
    }

    @Test func missingFileIsMissing() throws {
        let directory = try makeTemporaryDirectory()
        let state = try readCacheState(at: directory.appendingPathComponent("none.json"), previous: .unread)
        #expect(state == .missing)
    }

    @Test func unchangedFileIsNotReread() throws {
        let directory = try makeTemporaryDirectory()
        let modified = at("2026-11-17T09:00:00Z")
        let file = try writeCacheFile(cacheJSON(), modified: modified, in: directory)
        let first = try readCacheState(at: file, previous: .unread)
        // Same modification date, new contents: a re-read would show the new expiry.
        try cacheJSON(expiresAt: "2026-11-17T12:00:00Z").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        #expect(try readCacheState(at: file, previous: first) == first)
    }

    @Test func launchReadsHashOnceThenRenewalIsHashDecided() throws {
        let directory = try makeTemporaryDirectory()
        let modified = at("2026-11-17T09:00:00Z")
        let file = try writeCacheFile(cacheJSON(), modified: modified, in: directory)
        let stored = AWSCacheState.present(AWSCacheSnapshot(modified: modified, expiresAt: at("2026-11-17T10:00:00Z")))
        let read = try readCacheState(at: file, previous: stored)
        guard case .present(let snapshot) = read else { Issue.record("not present"); return }
        #expect(snapshot.refreshTokenHash != nil)
        #expect(observe(previous: stored, current: read, timerExpiry: at("2026-11-17T17:00:00Z"), leadTime: lead) == .noChange)

        // A rewrite with the same token, far from expiry, is a renewal.
        let renewedAt = at("2026-11-17T09:10:00Z")
        try cacheJSON(expiresAt: "2026-11-17T10:10:00Z").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: renewedAt], ofItemAtPath: file.path)
        let renewed = try readCacheState(at: file, previous: read)
        #expect(observe(previous: read, current: renewed, timerExpiry: at("2026-11-17T17:00:00Z"), leadTime: lead) == .renewed)
    }

    @Test func relaunchWithUnchangedFileIsNoChange() throws {
        let directory = try makeTemporaryDirectory()
        let modified = at("2026-11-17T09:00:00Z").addingTimeInterval(0.7)
        let file = try writeCacheFile(cacheJSON(), modified: modified, in: directory)
        guard case .present(let first) = try readCacheState(at: file, previous: .unread) else {
            Issue.record("not present"); return
        }
        let store = StateStore(directory: directory)
        try store.save(AppState(logins: [Login(
            displayName: "dev", kind: .awsSSOSession(name: "dev"),
            lastAWSCache: AWSCacheRecord(modified: first.modified, expiresAt: first.expiresAt))]))
        guard case .loaded(let loaded) = store.load(), let record = loaded.logins[0].lastAWSCache else {
            Issue.record("not loaded"); return
        }
        let previous = AWSCacheState.present(AWSCacheSnapshot(modified: record.modified, expiresAt: record.expiresAt))
        let current = try readCacheState(at: file, previous: previous)
        #expect(observe(previous: previous, current: current, timerExpiry: at("2026-11-17T17:00:00Z"), leadTime: lead) == .noChange)
    }
}

@Suite struct AWSObserveTests {
    private let timer = at("2026-11-17T17:00:00Z")

    @Test func observeCoversEveryStatePair() {
        let some = present("2026-11-17T09:00:00Z")
        let table: [(AWSCacheState, AWSCacheState, AWSCacheObservation)] = [
            (.unread, .unread, .noChange),
            (.unread, .missing, .noChange),
            (.unread, some, .noChange),
            (.missing, .unread, .noChange),
            (.missing, .missing, .noChange),
            (.missing, some, .newLogin(at: at("2026-11-17T09:00:00Z"))),
            (some, .unread, .noChange),
            (some, .missing, .loggedOut),
            (some, some, .noChange),
        ]
        for (previous, current, expected) in table {
            #expect(observe(previous: previous, current: current, timerExpiry: timer, leadTime: lead) == expected,
                "\(previous) to \(current)")
        }
    }

    @Test func firstObservationIsBaselineNotLogin() {
        #expect(observe(previous: .unread, current: present("2026-11-17T09:00:00Z"), timerExpiry: timer, leadTime: lead)
            == .noChange)
    }

    @Test func deletedFileIsLoggedOut() {
        #expect(observe(previous: present("2026-11-17T09:00:00Z"), current: .missing, timerExpiry: timer, leadTime: lead)
            == .loggedOut)
    }

    @Test func missingThenPresentIsLogin() {
        #expect(observe(previous: .missing, current: present("2026-11-17T09:00:00Z"), timerExpiry: timer, leadTime: lead)
            == .newLogin(at: at("2026-11-17T09:00:00Z")))
    }

    @Test func rewriteFarFromExpiryIsLogin() {
        let previous = present("2026-11-17T09:00:00Z", expires: "2026-11-17T10:00:00Z")
        let current = present("2026-11-17T09:20:00Z", expires: "2026-11-17T10:20:00Z")
        #expect(observe(previous: previous, current: current, timerExpiry: timer, leadTime: lead)
            == .newLogin(at: at("2026-11-17T09:20:00Z")))
    }

    @Test func rewriteNearExpiryIsRenewal() {
        let previous = present("2026-11-17T09:00:00Z", expires: "2026-11-17T10:00:00Z")
        let current = present("2026-11-17T09:50:00Z", expires: "2026-11-17T10:50:00Z")
        #expect(observe(previous: previous, current: current, timerExpiry: timer, leadTime: lead) == .renewed)
    }

    @Test func rewriteAfterTokenLapseIsRenewal() {
        let previous = present("2026-11-17T08:00:00Z", expires: "2026-11-17T09:00:00Z")
        let current = present("2026-11-17T11:00:00Z", expires: "2026-11-17T12:00:00Z")
        // Timer 2 h after the rewrite is ok and outside its 30 min lead time.
        #expect(observe(previous: previous, current: current, timerExpiry: at("2026-11-17T13:00:00Z"), leadTime: lead)
            == .renewed)
    }

    @Test func ambiguousRewriteWhileExpiringIsPossibleLogin() {
        let previous = present("2026-11-17T08:00:00Z", expires: "2026-11-17T09:00:00Z")
        let current = present("2026-11-17T11:00:00Z", expires: "2026-11-17T12:00:00Z")
        #expect(observe(previous: previous, current: current, timerExpiry: at("2026-11-17T11:20:00Z"), leadTime: lead)
            == .possibleLogin(at: at("2026-11-17T11:00:00Z")))
    }

    @Test func rewriteAfterTimerExpiryIsLogin() {
        let previous = present("2026-11-17T08:00:00Z", expires: "2026-11-17T09:00:00Z")
        let current = present("2026-11-17T11:00:00Z", expires: "2026-11-17T12:00:00Z")
        #expect(observe(previous: previous, current: current, timerExpiry: at("2026-11-17T10:30:00Z"), leadTime: lead)
            == .newLogin(at: at("2026-11-17T11:00:00Z")))
    }

    @Test func rewriteWithUnknownTimerIsPossibleLogin() {
        let previous = present("2026-11-17T07:00:00Z", expires: "2026-11-17T09:00:00Z")
        let current = present("2026-11-17T11:00:00Z", expires: "2026-11-17T12:00:00Z")
        #expect(observe(previous: previous, current: current, timerExpiry: nil, leadTime: lead)
            == .possibleLogin(at: at("2026-11-17T11:00:00Z")))
    }

    @Test func changedHashIsLogin() {
        let previous = present("2026-11-17T09:00:00Z", expires: "2026-11-17T10:00:00Z", hash: 1)
        let current = present("2026-11-17T09:55:00Z", expires: "2026-11-17T10:55:00Z", hash: 2)
        #expect(observe(previous: previous, current: current, timerExpiry: timer, leadTime: lead)
            == .newLogin(at: at("2026-11-17T09:55:00Z")))
    }

    @Test func missingHashIsNotLogin() {
        let previous = present("2026-11-17T09:00:00Z", expires: "2026-11-17T10:00:00Z", hash: 1)
        let current = present("2026-11-17T09:55:00Z", expires: "2026-11-17T10:55:00Z")
        #expect(observe(previous: previous, current: current, timerExpiry: timer, leadTime: lead) == .renewed)
    }

    @Test func sameHashIsRenewalEvenAfterTimerExpiry() {
        let previous = present("2026-11-17T09:00:00Z", expires: "2026-11-17T10:00:00Z", hash: 1)
        let current = present("2026-11-17T11:00:00Z", expires: "2026-11-17T12:00:00Z", hash: 1)
        #expect(observe(previous: previous, current: current, timerExpiry: at("2026-11-17T10:30:00Z"), leadTime: lead)
            == .renewed)
    }

    @Test func loginWhileAppClosedIsFoundAtLaunch() {
        let stored = present("2026-11-17T08:00:00Z", expires: "2026-11-17T09:00:00Z")
        let found = present("2026-11-17T08:20:00Z", expires: "2026-11-17T09:20:00Z", hash: 7)
        #expect(observe(previous: stored, current: found, timerExpiry: timer, leadTime: lead)
            == .newLogin(at: at("2026-11-17T08:20:00Z")))
    }
}
