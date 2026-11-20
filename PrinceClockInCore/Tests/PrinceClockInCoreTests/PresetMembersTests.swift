import Foundation
import Testing
import PrinceClockInCore

private func named(_ name: String) -> Login {
    Login(displayName: name, kind: .awsSSOSession(name: name))
}

private let dev = named("dev")
private let prod = named("prod")
private let staging = named("staging")

@Suite struct PresetMembersTests {
    // MARK: Adding and removing

    @Test func plusOffersTheTrackedLoginsNotInThePresetInStoredOrder() {
        let members = PresetMembers([prod.id])

        #expect(members.loginsToAdd(from: [dev, prod, staging]) == [dev, staging])
    }

    @Test func plusOffersNothingOnceEveryTrackedLoginIsIn() {
        let members = PresetMembers([prod.id, dev.id])

        #expect(members.loginsToAdd(from: [dev, prod]).isEmpty)
    }

    @Test func anAddedLoginGoesLast() {
        var members = PresetMembers([prod.id])

        members.add(dev.id)

        #expect(members.ids == [prod.id, dev.id])
    }

    @Test func addingALoginAlreadyInThePresetChangesNothing() {
        var members = PresetMembers([prod.id, dev.id])

        members.add(prod.id)

        #expect(members.ids == [prod.id, dev.id])
    }

    @Test func removingALoginKeepsTheOrderOfTheRest() {
        var members = PresetMembers([dev.id, prod.id, staging.id])

        members.remove(prod.id)

        #expect(members.ids == [dev.id, staging.id])
    }

    // MARK: Move Up and Move Down

    @Test func moveUpSwapsALoginWithTheOneBeforeIt() {
        var members = PresetMembers([dev.id, prod.id, staging.id])

        members.moveUp(staging.id)

        #expect(members.ids == [dev.id, staging.id, prod.id])
    }

    @Test func moveDownSwapsALoginWithTheOneAfterIt() {
        var members = PresetMembers([dev.id, prod.id, staging.id])

        members.moveDown(dev.id)

        #expect(members.ids == [prod.id, dev.id, staging.id])
    }

    @Test func moveUpIsUnavailableForTheFirstLoginAndWithNothingSelected() {
        let members = PresetMembers([dev.id, prod.id])

        #expect(!members.canMoveUp(dev.id))
        #expect(members.canMoveUp(prod.id))
        #expect(!members.canMoveUp(nil))
    }

    @Test func moveDownIsUnavailableForTheLastLoginAndWithNothingSelected() {
        let members = PresetMembers([dev.id, prod.id])

        #expect(members.canMoveDown(dev.id))
        #expect(!members.canMoveDown(prod.id))
        #expect(!members.canMoveDown(nil))
    }

    @Test func aLoginNotInThePresetCanMoveNeitherWay() {
        let members = PresetMembers([dev.id, prod.id])

        #expect(!members.canMoveUp(staging.id))
        #expect(!members.canMoveDown(staging.id))
    }

    @Test func movingPastEitherEndChangesNothing() {
        var members = PresetMembers([dev.id, prod.id])

        members.moveUp(dev.id)
        members.moveDown(prod.id)

        #expect(members.ids == [dev.id, prod.id])
    }

    // MARK: Drag

    @Test func draggingALoginDownPutsItBeforeTheRowItIsDroppedOn() {
        var members = PresetMembers([dev.id, prod.id, staging.id])

        members.move(fromOffsets: [0], toOffset: 2)

        #expect(members.ids == [prod.id, dev.id, staging.id])
    }

    @Test func draggingALoginToTheEndPutsItLast() {
        var members = PresetMembers([dev.id, prod.id, staging.id])

        members.move(fromOffsets: [0], toOffset: 3)

        #expect(members.ids == [prod.id, staging.id, dev.id])
    }

    @Test func draggingALoginUpPutsItAtTheRowItIsDroppedOn() {
        var members = PresetMembers([dev.id, prod.id, staging.id])

        members.move(fromOffsets: [2], toOffset: 0)

        #expect(members.ids == [staging.id, dev.id, prod.id])
    }

    @Test func draggingSeveralLoginsKeepsTheirOrder() {
        let qa = named("qa")
        var members = PresetMembers([dev.id, prod.id, staging.id, qa.id])

        members.move(fromOffsets: [0, 2], toOffset: 4)

        #expect(members.ids == [prod.id, qa.id, dev.id, staging.id])
    }
}
