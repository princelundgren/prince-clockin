import Foundation
import Testing
import PrinceClockInCore

private let hour: TimeInterval = 3600
private let minute: TimeInterval = 60
private let thirtyMinutes: TimeInterval = 30 * minute
private let now = at("2026-11-19T12:00:00Z")
private let british = Locale(identifier: "en_GB")
private let swedish = Locale(identifier: "sv_SE")

private func calendar(_ locale: Locale) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = locale
    calendar.timeZone = TimeZone(identifier: "Europe/Stockholm")!
    return calendar
}

private func tile(
    _ login: Login, facts: TileFacts = TileFacts(), locale: Locale = british
) -> TilePresentation {
    tilePresentation(
        for: login, now: now, leadTime: thirtyMinutes, facts: facts, locale: locale, calendar: calendar(locale))
}

/// A Databricks workspace login whose 1-day timer ran out an hour ago, found valid at `checkedAt`.
private func stillValid(checkedAt: Date) -> Login {
    var login = Login(
        displayName: "analytics-dev", kind: .databricksProfile(name: "analytics-dev", accountLevel: false),
        sessionLength: 24 * hour, loginTime: now.addingTimeInterval(-25 * hour))
    login.lastDatabricksAnswer = DatabricksCheckRecord(at: checkedAt, result: .valid)
    return login
}

private func noTimer(_ name: String = "analytics-prod") -> Login {
    Login(displayName: name, kind: .databricksProfile(name: name, accountLevel: false))
}

@Suite struct TilesTests {
    // MARK: Symbol and colour

    @Test func eachTimerStateHasItsSymbolAndColour() {
        let ok = tile(login(remaining: 5 * hour, now: now))
        let expiring = tile(login(remaining: 19 * minute, now: now))
        let expired = tile(login(remaining: -40 * minute, now: now))
        let unknown = tile(noTimer())
        let valid = tile(stillValid(checkedAt: now.addingTimeInterval(-10 * minute)))

        #expect(ok.symbol == .systemImage("checkmark.circle"))
        #expect(ok.colour == .loggedIn)
        #expect(expiring.symbol == .systemImage("clock"))
        #expect(expiring.colour == .expiring)
        #expect(expired.symbol == .systemImage("xmark.circle"))
        #expect(expired.colour == .expired)
        #expect(unknown.symbol == .systemImage("timer"))
        #expect(unknown.colour == nil)
        #expect(valid.symbol == .systemImage("clock.badge.checkmark"))
        #expect(valid.colour == .loggedIn)
    }

    @Test func pendingItemsAndActivityOverrideTheTimersSymbol() {
        let expired = login(remaining: -40 * minute, now: now)

        let failed = tile(expired, facts: TileFacts(failure: .timedOut))
        let question = tile(expired, facts: TileFacts(possibleLoginAt: now.addingTimeInterval(-5 * minute)))
        let running = tile(expired, facts: TileFacts(activity: .running, failure: .timedOut))
        let queued = tile(expired, facts: TileFacts(activity: .queued))

        #expect(failed.symbol == .systemImage("exclamationmark.triangle"))
        #expect(failed.colour == .expired)
        #expect(question.symbol == .systemImage("questionmark.circle"))
        #expect(question.colour == nil)
        #expect(running.symbol == .progress)
        #expect(running.colour == .running)
        #expect(queued.symbol == .progress)
        #expect(queued.colour == .running)
    }

    @Test func aCommandNotYetApprovedShowsTheTerminalSymbol() {
        let vpn = Login(displayName: "vpn", kind: .custom(command: "vpn-login"), sessionLength: 8 * hour)

        let approval = tile(vpn, facts: TileFacts(isAwaitingApproval: true))

        #expect(approval.symbol == .systemImage("terminal"))
        #expect(approval.colour == nil)
    }

    @Test func colourTokensNameTheAssetCatalogColours() {
        #expect(ColourToken.expired.rawValue == "Expired")
        #expect(ColourToken.expiring.rawValue == "Expiring")
        #expect(ColourToken.loggedIn.rawValue == "LoggedIn")
        #expect(ColourToken.running.rawValue == "Running")
    }

    // MARK: Subtitle and trailing

    @Test func aTileThatIsntDueShowsItsKindAndTimeLeft() {
        let prod = tile(login(remaining: 5 * hour + 13 * minute, now: now, name: "prod"))

        #expect(prod.name == "prod")
        #expect(prod.subtitle == .kind("AWS SSO session"))
        #expect(prod.trailing == .timeLeft("5h 13m"))
    }

    @Test func eachKindHasItsGlossaryName() {
        let account = Login(displayName: "account", kind: .databricksProfile(name: "account", accountLevel: true))
        let custom = Login(displayName: "vpn", kind: .custom(command: nil))

        #expect(tile(noTimer()).subtitle == .kind("Databricks profile"))
        #expect(tile(account).subtitle == .kind("Databricks account profile"))
        #expect(tile(custom).subtitle == .kind("Custom login"))
    }

    @Test func aTileWithNoTimerSaysSo() {
        #expect(tile(noTimer()).trailing == .stateWord("No timer"))
    }

    @Test func anExpiringTileShowsItsTimeLeftAndLogIn() {
        let qa = tile(login(remaining: 19 * minute, now: now, name: "qa"))

        #expect(qa.subtitle == .status("Expiring · 19m left"))
        #expect(qa.trailing == .logIn)
    }

    @Test func anExpiredTileShowsHowLongAgo() {
        let qa = tile(login(remaining: -40 * minute, now: now, name: "qa"))

        #expect(qa.subtitle == .status("Expired 40m ago"))
        #expect(qa.trailing == .logIn)
    }

    @Test func anExpiredTileUnderAMinuteAgoUsesTheOneShortForm() {
        let justNow = tile(login(remaining: 0, now: now))

        #expect(justNow.subtitle == .status("Expired <1m ago"))
    }

    @Test func aLoggedOutSessionSaysLoggedOut() {
        var dev = login(remaining: 4 * hour, now: now)
        dev.invalidatedAt = now.addingTimeInterval(-30 * minute)
        dev.invalidationReason = .loggedOut

        #expect(tile(dev).subtitle == .status("Logged out"))
    }

    @Test func aProfileFoundInvalidCountsFromWhenItWasFound() {
        var profile = Login(
            displayName: "analytics-dev", kind: .databricksProfile(name: "analytics-dev", accountLevel: false),
            sessionLength: 24 * hour, loginTime: now.addingTimeInterval(-hour))
        profile.invalidatedAt = now.addingTimeInterval(-12 * minute)
        profile.invalidationReason = .foundInvalid

        #expect(tile(profile).subtitle == .status("Expired 12m ago"))
    }

    @Test func aStillValidTileCarriesItsCheck() {
        let valid = tile(stillValid(checkedAt: at("2026-11-19T11:30:00Z")))

        #expect(valid.subtitle == .status("Checked 12:30 · valid"))
        #expect(valid.trailing == .stateWord("Still valid"))
    }

    @Test func aPendingItemShowsItsStateWordInsteadOfLogIn() {
        let expired = login(remaining: -40 * minute, now: now)
        let vpn = Login(displayName: "vpn", kind: .custom(command: "vpn-login"), sessionLength: 8 * hour)

        #expect(tile(expired, facts: TileFacts(failure: .timedOut)).trailing == .stateWord("Failed"))
        #expect(tile(vpn, facts: TileFacts(isAwaitingApproval: true)).trailing == .stateWord("Not yet approved"))
        #expect(tile(expired, facts: TileFacts(possibleLoginAt: now)).trailing == .stateWord("Expired"))
    }

    @Test func aRunningOrQueuedTileSaysSo() {
        let expired = login(remaining: -40 * minute, now: now)

        #expect(tile(expired, facts: TileFacts(activity: .running)).trailing == .stateWord("Logging in"))
        #expect(tile(expired, facts: TileFacts(activity: .queued)).trailing == .stateWord("Queued"))
    }

    @Test func swedishTimesJoinNumberAndUnit() {
        let prod = tile(login(remaining: 5 * hour + 13 * minute, now: now), locale: swedish)
        let qa = tile(login(remaining: 19 * minute, now: now), locale: swedish)

        #expect(prod.trailing == .timeLeft("5\u{202F}h 13\u{202F}m"))
        #expect(qa.subtitle == .status("Expiring · 19\u{202F}m left"))
    }

    // MARK: Control

    @Test func onlyADueTileWithNothingPendingIsALogInButton() {
        let expiring = login(remaining: 19 * minute, now: now)

        #expect(tile(expiring).control == .logInButton)
        #expect(tile(login(remaining: 5 * hour, now: now)).control == .actionsMenu)
        #expect(tile(noTimer()).control == .actionsMenu)
        #expect(tile(stillValid(checkedAt: now)).control == .actionsMenu)
        #expect(tile(expiring, facts: TileFacts(failure: .timedOut)).control == .actionsMenu)
        #expect(tile(expiring, facts: TileFacts(possibleLoginAt: now)).control == .actionsMenu)
        #expect(tile(expiring, facts: TileFacts(activity: .queued)).control == .actionsMenu)
        #expect(tile(expiring, facts: TileFacts(activity: .running)).control == .actionsMenu)
    }

    @Test func aHeldControlKeepsTheClicksActionAsTheStateChanges() {
        let becameDue = login(remaining: 29 * minute, now: now)
        let gotQuestion = login(remaining: 19 * minute, now: now)

        let menu = tilePresentation(
            for: becameDue, now: now, leadTime: thirtyMinutes, facts: TileFacts(), holding: .actionsMenu,
            locale: british, calendar: calendar(british))
        let button = tilePresentation(
            for: gotQuestion, now: now, leadTime: thirtyMinutes, facts: TileFacts(possibleLoginAt: now),
            holding: .logInButton, locale: british, calendar: calendar(british))

        #expect(menu.control == .actionsMenu)
        #expect(menu.trailing == .timeLeft("29m"))
        #expect(menu.accessibilityHint == "Shows actions")
        #expect(button.control == .logInButton)
        #expect(button.trailing == .timeLeft("19m"))
        #expect(!button.clickLogsIn)
    }

    @Test func aHeldLogInButtonShowsWhatIsPendingAndDoesNothing() {
        let expiring = login(remaining: 19 * minute, now: now)
        let vpn = Login(
            displayName: "vpn", kind: .custom(command: "vpn-login --user dev"), sessionLength: 8 * hour,
            loginTime: now.addingTimeInterval(-8 * hour + 19 * minute))
        func held(_ login: Login, _ facts: TileFacts) -> TilePresentation {
            tilePresentation(
                for: login, now: now, leadTime: thirtyMinutes, facts: facts, holding: .logInButton,
                locale: british, calendar: calendar(british))
        }

        let running = held(expiring, TileFacts(activity: .running))
        let queued = held(expiring, TileFacts(activity: .queued))
        let failed = held(expiring, TileFacts(failure: .timedOut))
        let notApproved = held(vpn, TileFacts(isAwaitingApproval: true))

        #expect(running.trailing == .stateWord("Logging in"))
        #expect(queued.trailing == .stateWord("Queued"))
        #expect(failed.trailing == .stateWord("Failed"))
        #expect(notApproved.trailing == .stateWord("Not yet approved"))
        for tile in [running, queued, failed, notApproved] {
            #expect(tile.control == .logInButton)
            #expect(!tile.clickLogsIn)
        }
        #expect(held(expiring, TileFacts()).clickLogsIn)
        #expect(held(expiring, TileFacts()).trailing == .logIn)
    }

    @Test func aHeldLogInButtonOnATileNoLongerDueShowsItsTimeAndDoesNothing() {
        let loggedIn = tilePresentation(
            for: login(remaining: 5 * hour, now: now), now: now, leadTime: thirtyMinutes, facts: TileFacts(),
            holding: .logInButton, locale: british, calendar: calendar(british))

        #expect(loggedIn.control == .logInButton)
        #expect(!loggedIn.clickLogsIn)
        #expect(loggedIn.trailing == .timeLeft("5h"))
    }

    @Test func dueFollowsTheTimerNotWhatIsPending() {
        let expiring = login(remaining: 19 * minute, now: now)

        #expect(tile(expiring).isDue)
        #expect(tile(expiring, facts: TileFacts(failure: .timedOut)).isDue)
        #expect(!tile(stillValid(checkedAt: now)).isDue)
        #expect(!tile(noTimer()).isDue)
    }

    // MARK: Below the tile

    @Test func aFailedTileShowsTheCoresMessage() {
        let dev = login(remaining: -hour, now: now)

        #expect(tile(dev, facts: TileFacts(failure: .cliNotFound("aws"))).detail
            == .failed(message: "aws not found on your login shell's PATH"))
    }

    @Test func aPossibleLoginAsksWithItsTime() {
        let dev = login(remaining: 10 * minute, now: now)
        let changed = at("2026-11-19T13:02:00Z")

        let detail = tile(dev, facts: TileFacts(possibleLoginAt: changed)).detail

        #expect(detail == .possibleLogin(
            question: "Its login changed at 14:02. Was that you?", confirmTitle: "Mark as Logged In at 14:02"))
    }

    @Test func aPossibleLoginFoundOnWakingSaysTheMacSlept() {
        let dev = login(remaining: 10 * minute, now: now)
        let changed = at("2026-11-19T09:48:00Z")

        let detail = tile(dev, facts: TileFacts(possibleLoginAt: changed, isPossibleLoginFoundOnWake: true)).detail

        #expect(detail == .possibleLogin(
            question: "Its login changed at 10:48, while this Mac slept. Was that you?",
            confirmTitle: "Mark as Logged In at 10:48"))
    }

    @Test func aPossibleLoginOnAnotherDayNamesTheDay() throws {
        // `DateFormatter`'s relative formatting reads the real clock, so the fixture is built from it.
        let britishCalendar = calendar(british)
        let today = Date.now
        let yesterday = try #require(britishCalendar.date(byAdding: .day, value: -1, to: today))
        let changed = try #require(britishCalendar.date(bySettingHour: 23, minute: 40, second: 0, of: yesterday))

        let detail = tilePresentation(
            for: login(remaining: 10 * minute, now: today), now: today, leadTime: thirtyMinutes,
            facts: TileFacts(possibleLoginAt: changed), locale: british, calendar: britishCalendar
        ).detail

        #expect(detail == .possibleLogin(
            question: "Its login changed yesterday at 23:40. Was that you?",
            confirmTitle: "Mark as Logged In yesterday at 23:40"))
    }

    @Test func aStillValidTileSaysItsSessionLengthMayBeTooShort() {
        #expect(tile(stillValid(checkedAt: now)).detail == .stillValid(
            message: "Its 1-day timer ran out, but Databricks says the login still works. The session length may be too short."))
    }

    @Test func aCommandNotYetApprovedIsShown() {
        let vpn = Login(displayName: "vpn", kind: .custom(command: "vpn-login --user dev"), sessionLength: 8 * hour)

        #expect(tile(vpn, facts: TileFacts(isAwaitingApproval: true)).detail
            == .notYetApproved(command: "vpn-login --user dev"))
    }

    @Test func aFailureComesBeforeAQuestion() {
        let dev = login(remaining: 10 * minute, now: now)

        let detail = tile(dev, facts: TileFacts(failure: .timedOut, possibleLoginAt: now)).detail

        #expect(detail == .failed(message: "The login timed out"))
    }

    @Test func aRunningOrQueuedTileShowsNothingBelow() {
        let dev = login(remaining: 10 * minute, now: now)

        #expect(tile(dev, facts: TileFacts(activity: .running, possibleLoginAt: now)).detail == nil)
        #expect(tile(dev, facts: TileFacts(activity: .queued, failure: .timedOut)).detail == nil)
    }

    @Test func aTileWithNothingPendingShowsNothingBelow() {
        #expect(tile(login(remaining: 5 * hour, now: now)).detail == nil)
        #expect(tile(login(remaining: -hour, now: now)).detail == nil)
    }

    // MARK: The "…" menu

    @Test func theActionsMenuHasItsItemsInOrder() {
        let dev = tile(login(remaining: 5 * hour, now: now))

        #expect(dev.menuItems == [
            .logIn, .setTimer, .markLoggedInNow(opensSetTimer: false), .sessionLength, .editInSettings,
        ])
        #expect(dev.menuItems.map(\.title) == [
            "Log In", "Set Timer…", "Mark as Logged In Now", "Session Length", "Edit in Settings…",
        ])
    }

    @Test func aRunningOrQueuedTileAddsCancelAll() {
        let dev = login(remaining: 5 * hour, now: now)

        #expect(tile(dev, facts: TileFacts(activity: .running)).menuItems.last == .cancelAll)
        #expect(tile(dev, facts: TileFacts(activity: .queued)).menuItems.last == .cancelAll)
        #expect(TileMenuItem.cancelAll.title == "Cancel All")
    }

    @Test func markAsLoggedInNowAsksForAnUnknownSessionLength() {
        #expect(tile(noTimer()).menuItems.contains(.markLoggedInNow(opensSetTimer: true)))
    }

    @Test func sessionLengthOptionsCheckTheCurrentLength() {
        let options = sessionLengthOptions(current: 24 * hour)

        #expect(options.map(\.title) == ["8 hours", "12 hours", "1 day", "3 days", "7 days", "Custom…", "No timer"])
        #expect(options.filter(\.isSelected).map(\.title) == ["1 day"])
        #expect(options[0].choice == .length(8 * hour))
        #expect(options[5].choice == .custom)
        #expect(options[6].choice == .noTimer)
    }

    @Test func anUnlistedLengthChecksCustomAndNoneChecksNoTimer() {
        #expect(sessionLengthOptions(current: 10 * hour).filter(\.isSelected).map(\.title) == ["Custom…"])
        #expect(sessionLengthOptions(current: nil).filter(\.isSelected).map(\.title) == ["No timer"])
    }

    @Test func sessionLengthsReadInHoursOrDays() {
        #expect(sessionLengthText(8 * hour) == "8 hours")
        #expect(sessionLengthText(hour) == "1 hour")
        #expect(sessionLengthText(24 * hour) == "1 day")
        #expect(sessionLengthText(72 * hour) == "3 days")
        #expect(sessionLengthText(36 * hour) == "36 hours")
        #expect(sessionLengthText(90 * minute) == "90 minutes")
    }

    // MARK: VoiceOver

    @Test func voiceOverReadsNameKindStateAndTime() {
        let prod = tile(login(remaining: 19 * minute, now: now, name: "prod"))

        #expect(prod.accessibilityLabel == "prod, AWS SSO session, expiring, 19 minutes left")
        #expect(prod.accessibilityHint == "Logs in")
        #expect(prod.actionsLabel == "Actions for prod")
    }

    @Test func voiceOverReadsEachTimerState() {
        let ok = tile(login(remaining: 5 * hour + 13 * minute, now: now, name: "dev"))
        let expired = tile(login(remaining: -40 * minute, now: now, name: "qa"))
        let unknown = tile(noTimer("analytics-prod"))
        let valid = tile(stillValid(checkedAt: now))
        let underAMinute = tile(login(remaining: 30, now: now, name: "dev"))

        #expect(ok.accessibilityLabel == "dev, AWS SSO session, logged in, 5 hours, 13 minutes left")
        #expect(ok.accessibilityHint == "Shows actions")
        #expect(expired.accessibilityLabel == "qa, AWS SSO session, expired, 40 minutes ago")
        #expect(unknown.accessibilityLabel == "analytics-prod, Databricks profile, No timer")
        #expect(valid.accessibilityLabel == "analytics-dev, Databricks profile, still valid")
        #expect(underAMinute.accessibilityLabel == "dev, AWS SSO session, expiring, less than a minute left")
    }

    @Test func voiceOverReadsWhatIsPendingInPlaceOfTheTimersState() {
        let expired = login(remaining: -40 * minute, now: now, name: "qa")
        let expiring = login(remaining: 19 * minute, now: now, name: "prod")

        #expect(tile(expired, facts: TileFacts(failure: .timedOut)).accessibilityLabel
            == "qa, AWS SSO session, failed, 40 minutes ago")
        #expect(tile(expired, facts: TileFacts(activity: .running)).accessibilityLabel
            == "qa, AWS SSO session, logging in, 40 minutes ago")
        #expect(tile(expired, facts: TileFacts(possibleLoginAt: now)).accessibilityLabel
            == "qa, AWS SSO session, logged in elsewhere?, 40 minutes ago")
        #expect(tile(expiring, facts: TileFacts(activity: .queued)).accessibilityLabel
            == "prod, AWS SSO session, queued, 19 minutes left")
        #expect(tile(noTimer(), facts: TileFacts(failure: .timedOut)).accessibilityLabel
            == "analytics-prod, Databricks profile, failed, No timer")
    }

    @Test func voiceOverReadsSwedishDurationsWide() {
        let prod = tile(login(remaining: 5 * hour + 13 * minute, now: now, name: "prod"), locale: swedish)

        #expect(prod.accessibilityLabel == "prod, AWS SSO session, logged in, 5 timmar, 13 minuter left")
    }
}
