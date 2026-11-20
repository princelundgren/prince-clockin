import Testing
import PrinceClockInCore

private func tiles(_ count: Int) -> [Double] { Array(repeating: 40, count: count) }

@Suite struct PanelListHeightsTests {
    @Test func eightLoginsAndThreePresetsShowWhole() {
        let heights = panelListHeights(loginTiles: tiles(8), presetTiles: tiles(3), spacing: 6, room: 2000)

        #expect(heights == PanelListHeights(logins: 8 * 40 + 7 * 6, presets: 3 * 40 + 2 * 6))
    }

    @Test func pastEightLoginsTheNinthShowsHalfSoTheListReadsAsScrolling() {
        let heights = panelListHeights(loginTiles: tiles(12), presetTiles: [], spacing: 6, room: 2000)

        #expect(heights.logins == 8 * 40 + 8 * 6 + 20)
    }

    @Test func presetsGrowToFiveWithRoomThenScroll() {
        let heights = panelListHeights(loginTiles: tiles(2), presetTiles: tiles(7), spacing: 6, room: 2000)

        #expect(heights.presets == 5 * 40 + 5 * 6 + 20)
    }

    @Test func aPresetDoesNotTakeRoomFromTheLoginsWhenTheScreenHasRoom() {
        let without = panelListHeights(loginTiles: tiles(8), presetTiles: [], spacing: 6, room: 2000)
        let with = panelListHeights(loginTiles: tiles(8), presetTiles: tiles(4), spacing: 6, room: 2000)

        #expect(with.logins == without.logins)
    }

    @Test func onAShortScreenTheLoginsShrinkAndThreeAndAHalfPresetsStay() {
        let heights = panelListHeights(loginTiles: tiles(8), presetTiles: tiles(5), spacing: 6, room: 300)

        let threePresetsAndAHalf = 3 * 40 + 3 * 6 + 20.0
        #expect(heights == PanelListHeights(logins: 300 - threePresetsAndAHalf, presets: threePresetsAndAHalf))
    }

    @Test func roomLeftAfterEightLoginsGoesToPresetsPastThree() {
        let eightLogins = 8 * 40 + 7 * 6.0
        let threePresets = 3 * 40 + 3 * 6 + 20.0

        let heights = panelListHeights(
            loginTiles: tiles(8), presetTiles: tiles(5), spacing: 6, room: eightLogins + threePresets + 10)

        #expect(heights == PanelListHeights(logins: eightLogins, presets: threePresets + 10))
    }

    @Test func eachTileCountsAtItsOwnHeight() {
        let heights = panelListHeights(
            loginTiles: [40, 90] + tiles(6) + [100, 40], presetTiles: [], spacing: 6, room: nil)

        let eightTilesAndTheirGaps: Double = 40 + 90 + 6 * 40 + 8 * 6
        #expect(heights.logins == eightTilesAndTheirGaps + 100 / 2)
    }

    @Test func roomShorterThanThreePresetsGoesToThePresets() {
        let heights = panelListHeights(loginTiles: tiles(8), presetTiles: tiles(5), spacing: 6, room: 100)

        #expect(heights == PanelListHeights(logins: 0, presets: 100))
    }

    @Test func roomBelowZeroGivesBothListsNoHeight() {
        let heights = panelListHeights(loginTiles: tiles(8), presetTiles: tiles(5), spacing: 6, room: -10)

        #expect(heights == PanelListHeights(logins: 0, presets: 0))
    }

    @Test func withoutAScreenTheListsTakeWhatTheyWant() {
        let heights = panelListHeights(loginTiles: tiles(3), presetTiles: tiles(1), spacing: 6, room: nil)

        #expect(heights == PanelListHeights(logins: 3 * 40 + 2 * 6, presets: 40))
    }

    @Test func noTilesTakeNoHeight() {
        #expect(panelListHeights(loginTiles: [], presetTiles: [], spacing: 6, room: 500)
            == PanelListHeights(logins: 0, presets: 0))
    }
}
