import Foundation
import Testing
import PrinceClockInCore

private let hour: TimeInterval = 3600
private let now = at("2026-11-19T12:00:00Z")

private func tile(_ login: Login, facts: TileFacts = TileFacts()) -> TilePresentation {
    tilePresentation(
        for: login, now: now, leadTime: hour / 2, facts: facts, locale: Locale(identifier: "en_GB"),
        calendar: Calendar(identifier: .gregorian))
}

private func tile(remaining: TimeInterval, name: String, facts: TileFacts = TileFacts()) -> TilePresentation {
    tile(login(remaining: remaining, now: now, name: name), facts: facts)
}

@Suite struct ProminentActionTests {
    @Test func setInAnOpenSetTimerComesFirst() {
        let due = tile(remaining: 10 * 60, name: "prod")
        let ok = tile(remaining: 5 * hour, name: "staging")

        #expect(prominentAction(
            openSetTimer: ok.id, waitingForDone: UUID(), tiles: [due, ok], showsLogInToDue: true, isBatchRunning: true)
            == .set(id: ok.id))
    }

    @Test func aSetTimerWhoseLoginIsGoneIsNotProminent() {
        let due = tile(remaining: 10 * 60, name: "prod")

        #expect(prominentAction(
            openSetTimer: UUID(), waitingForDone: nil, tiles: [due], showsLogInToDue: false, isBatchRunning: false)
            == .logIn(id: due.id))
    }

    @Test func doneWhileACustomLoginWaitsComesNext() {
        let vpn = UUID()
        let due = tile(remaining: 10 * 60, name: "prod")

        #expect(prominentAction(
            openSetTimer: nil, waitingForDone: vpn, tiles: [due], showsLogInToDue: true, isBatchRunning: true)
            == .done(id: vpn))
    }

    @Test func logInToDueComesBeforeTheTiles() {
        let tiles = [tile(remaining: -hour, name: "dev"), tile(remaining: 10 * 60, name: "prod")]

        #expect(prominentAction(openSetTimer: nil, waitingForDone: nil, tiles: tiles, showsLogInToDue: true, isBatchRunning: false) == .logInToDue)
    }

    @Test func otherwiseTheFirstDueTilesLogIn() {
        let question = tile(remaining: 5 * hour, name: "qa", facts: TileFacts(possibleLoginAt: now))
        let ok = tile(remaining: 5 * hour, name: "staging")
        let due = tile(remaining: 10 * 60, name: "prod")

        #expect(prominentAction(openSetTimer: nil, waitingForDone: nil, tiles: [question, ok, due], showsLogInToDue: false, isBatchRunning: false)
            == .logIn(id: due.id))
    }

    @Test func aRunningDueTileIsNotProminent() {
        let running = tile(remaining: 10 * 60, name: "dev", facts: TileFacts(activity: .running))

        #expect(prominentAction(openSetTimer: nil, waitingForDone: nil, tiles: [running], showsLogInToDue: false, isBatchRunning: true) == nil)
    }

    @Test func aFailedDueTileOffersTryAgain() {
        let failed = tile(remaining: -hour, name: "dev", facts: TileFacts(failure: .timedOut))

        #expect(prominentAction(openSetTimer: nil, waitingForDone: nil, tiles: [failed], showsLogInToDue: false, isBatchRunning: false)
            == .tryAgain(id: failed.id))
    }

    @Test func tryAgainIsNeverProminentDuringABatch() {
        let failed = tile(remaining: -hour, name: "dev", facts: TileFacts(failure: .timedOut))
        let question = tile(remaining: 5 * hour, name: "qa", facts: TileFacts(possibleLoginAt: now))

        #expect(prominentAction(openSetTimer: nil, waitingForDone: nil, tiles: [failed, question], showsLogInToDue: false, isBatchRunning: true)
            == .markAsLoggedInAt(id: question.id))
    }

    @Test func aRunningDueTileGivesWayToTheNextDueTile() {
        let running = tile(remaining: -hour, name: "dev", facts: TileFacts(activity: .running))
        let due = tile(remaining: 10 * 60, name: "prod")

        #expect(prominentAction(openSetTimer: nil, waitingForDone: nil, tiles: [running, due], showsLogInToDue: false, isBatchRunning: true)
            == .logIn(id: due.id))
    }

    @Test func otherwiseTheFirstQuestion() {
        let first = tile(remaining: 5 * hour, name: "qa", facts: TileFacts(possibleLoginAt: now))
        let second = tile(remaining: 5 * hour, name: "staging", facts: TileFacts(possibleLoginAt: now))

        #expect(prominentAction(openSetTimer: nil, waitingForDone: nil, tiles: [first, second], showsLogInToDue: false, isBatchRunning: false)
            == .markAsLoggedInAt(id: first.id))
    }

    @Test func nothingIsProminentWhenNothingNeedsTheUser() {
        let ok = tile(remaining: 5 * hour, name: "dev")
        let running = tile(remaining: -hour, name: "prod", facts: TileFacts(activity: .running))

        #expect(prominentAction(openSetTimer: nil, waitingForDone: nil, tiles: [ok, running], showsLogInToDue: false, isBatchRunning: true) == nil)
        #expect(prominentAction(openSetTimer: nil, waitingForDone: nil, tiles: [], showsLogInToDue: false, isBatchRunning: false) == nil)
    }

    @Test func runItIsNeverProminent() {
        let expired = Login(
            displayName: "vpn", kind: .custom(command: "vpn-login"), sessionLength: 8 * hour,
            loginTime: now.addingTimeInterval(-9 * hour))
        let vpn = tile(expired, facts: TileFacts(isAwaitingApproval: true))

        #expect(vpn.isDue)
        #expect(prominentAction(openSetTimer: nil, waitingForDone: nil, tiles: [vpn], showsLogInToDue: false, isBatchRunning: false) == nil)
    }
}
