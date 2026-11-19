import Foundation
import Testing
import PrinceClockInCore

private let prod = Login(displayName: "prod", kind: .awsSSOSession(name: "prod"))
private let staging = Login(displayName: "staging", kind: .awsSSOSession(name: "staging"))
private let analytics = Login(displayName: "analytics-dev", kind: .databricksProfile(name: "analytics-dev", accountLevel: false))
private let vpn = Login(displayName: "vpn", kind: .custom(command: "vpn-login"))
private let manualVPN = Login(displayName: "vpn", kind: .custom(command: nil))

@Suite struct BatchCardTests {
    @Test func namesTheLoginRunningItsProgressAndTheNextOne() {
        let card = batchCard(
            batch: BatchProgress(position: 1, total: 2), running: prod, next: staging, outcomes: [],
            waitingForDone: nil)

        #expect(card == .running(
            title: "Logging in to prod", progress: "1 of 2", instruction: "Finish in your browser. Next: staging",
            failures: nil))
    }

    @Test func theLastLoginHasNoNext() {
        let card = batchCard(
            batch: BatchProgress(position: 2, total: 2), running: analytics, next: nil, outcomes: [],
            waitingForDone: nil)

        #expect(card == .running(
            title: "Logging in to analytics-dev", progress: "2 of 2", instruction: "Finish in your browser.",
            failures: nil))
    }

    @Test func countsTheFailuresButNotTheCancelledUnderTheProgress() {
        let outcomes: [LoginOutcome] = [
            .failed(id: prod.id, reason: .timedOut), .cancelled(id: analytics.id), .succeeded(id: vpn.id),
        ]

        let card = batchCard(
            batch: BatchProgress(position: 4, total: 4), running: staging, next: nil, outcomes: outcomes,
            waitingForDone: nil)

        #expect(card == .running(
            title: "Logging in to staging", progress: "4 of 4", instruction: "Finish in your browser.",
            failures: "1 failed"))
    }

    @Test func aCustomLoginStartingInTerminalNamesOnlyTheNextOne() {
        let card = batchCard(
            batch: BatchProgress(position: 1, total: 2), running: vpn, next: prod, outcomes: [], waitingForDone: nil)

        #expect(card == .running(title: "Logging in to vpn", progress: "1 of 2", instruction: "Next: prod", failures: nil))
    }

    @Test func aCustomLoginWaitingForDoneAsksForIt() {
        let card = batchCard(
            batch: BatchProgress(position: 1, total: 2), running: vpn, next: prod, outcomes: [], waitingForDone: vpn)

        #expect(card == .waitingForDone(
            id: vpn.id, title: "vpn is waiting for you", instruction: "Finish the login in Terminal, then click Done."))
    }

    @Test func aCustomLoginWithoutACommandIsDoneTheUsersOwnWay() {
        let card = batchCard(
            batch: BatchProgress(position: 1, total: 1), running: manualVPN, next: nil, outcomes: [],
            waitingForDone: manualVPN)

        #expect(card == .waitingForDone(
            id: manualVPN.id, title: "vpn is waiting for you", instruction: "Log in your own way, then click Done."))
    }

    @Test func betweenTwoLoginsTheCardNamesNoLogin() {
        let card = batchCard(
            batch: BatchProgress(position: 1, total: 2), running: nil, next: staging, outcomes: [.succeeded(id: prod.id)],
            waitingForDone: nil)

        #expect(card == .running(title: "Logging in", progress: "1 of 2", instruction: "Next: staging", failures: nil))
    }
}
