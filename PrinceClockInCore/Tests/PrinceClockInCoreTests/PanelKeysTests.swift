import Foundation
import Testing
import PrinceClockInCore

private let dev = UUID()
private let prod = UUID()
private let qa = UUID()

private func context(
    prominent: ProminentAction? = .logInToDue, openSetTimer: UUID? = nil, isEditingText: Bool = false,
    focusedTile: UUID? = nil
) -> PanelKeyContext {
    PanelKeyContext(
        prominent: prominent, openSetTimer: openSetTimer, isEditingText: isEditingText, tiles: [dev, prod, qa],
        focusedTile: focusedTile)
}

@Suite struct PanelKeysTests {
    // MARK: Return

    @Test func returnTriggersTheProminentActionWhereverFocusIs() {
        #expect(panelKeyResponse(to: .returnKey, in: context()) == .perform(.logInToDue))
        #expect(panelKeyResponse(to: .returnKey, in: context(focusedTile: qa)) == .perform(.logInToDue))
        #expect(panelKeyResponse(to: .returnKey, in: context(prominent: .set(id: dev), openSetTimer: dev))
            == .perform(.set(id: dev)))
    }

    @Test func returnInATextFieldIsLeftToTheField() {
        #expect(panelKeyResponse(
            to: .returnKey, in: context(prominent: .set(id: dev), openSetTimer: dev, isEditingText: true))
            == .passThrough)
    }

    @Test func returnDoesNothingWhenNothingIsProminent() {
        #expect(panelKeyResponse(to: .returnKey, in: context(prominent: nil)) == .passThrough)
    }

    // MARK: Escape

    @Test func escapeCancelsAnOpenSetTimerWhoseLoginIsShown() {
        #expect(escapeResponse(openSetTimer: prod, tiles: [dev, prod, qa]) == .cancelSetTimer(id: prod))
    }

    @Test func escapeOtherwiseClosesThePanel() {
        #expect(escapeResponse(openSetTimer: nil, tiles: [dev, prod, qa]) == .closePanel)
        #expect(escapeResponse(openSetTimer: nil, tiles: []) == .closePanel)
    }

    @Test func escapeClosesThePanelWhenTheSetTimersLoginIsGone() {
        #expect(escapeResponse(openSetTimer: UUID(), tiles: [dev, prod, qa]) == .closePanel)
    }

    // MARK: A Set Timer on its own

    @Test func aSetTimerOnItsOwnSetsOnReturnAndCancelsOnEscapeAsInThePanel() {
        let alone = PanelKeyContext.setTimerAlone(id: dev, isEditingText: false)
        let editing = PanelKeyContext.setTimerAlone(id: dev, isEditingText: true)

        #expect(alone.prominent == .set(id: dev))
        #expect(panelKeyResponse(to: .returnKey, in: alone) == .perform(.set(id: dev)))
        #expect(panelKeyResponse(to: .returnKey, in: editing) == .passThrough)
        #expect(escapeResponse(openSetTimer: alone.openSetTimer, tiles: alone.tiles) == .cancelSetTimer(id: dev))
    }

    // MARK: Arrows

    @Test func theArrowKeysMoveBetweenTilesInPanelOrder() {
        #expect(panelKeyResponse(to: .moveDown, in: context(focusedTile: dev)) == .focusTile(prod))
        #expect(panelKeyResponse(to: .moveUp, in: context(focusedTile: qa)) == .focusTile(prod))
    }

    @Test func theArrowKeysStopAtTheFirstAndLastTile() {
        #expect(panelKeyResponse(to: .moveUp, in: context(focusedTile: dev)) == .passThrough)
        #expect(panelKeyResponse(to: .moveDown, in: context(focusedTile: qa)) == .passThrough)
    }

    @Test func theArrowKeysAreLeftAloneAwayFromTheTiles() {
        #expect(panelKeyResponse(to: .moveDown, in: context()) == .passThrough)
        #expect(panelKeyResponse(to: .moveDown, in: context(focusedTile: UUID())) == .passThrough)
    }
}
