import Foundation
import Testing
import PrinceClockInCore

private func named(_ name: String) -> Login {
    Login(displayName: name, kind: .awsSSOSession(name: name))
}

private let dev = named("dev")
private let prod = named("prod")
private let staging = named("staging")

@Suite struct ListOrderTests {
    // MARK: Adding and removing

    @Test func plusOffersTheTrackedLoginsNotInTheListInStoredOrder() {
        let order = ListOrder([prod.id])

        #expect(order.loginsToAdd(from: [dev, prod, staging]) == [dev, staging])
    }

    @Test func plusOffersNothingOnceEveryTrackedLoginIsIn() {
        let order = ListOrder([prod.id, dev.id])

        #expect(order.loginsToAdd(from: [dev, prod]).isEmpty)
    }

    @Test func anAddedLoginGoesLast() {
        var order = ListOrder([prod.id])

        order.add(dev.id)

        #expect(order.ids == [prod.id, dev.id])
    }

    @Test func addingALoginAlreadyInTheListChangesNothing() {
        var order = ListOrder([prod.id, dev.id])

        order.add(prod.id)

        #expect(order.ids == [prod.id, dev.id])
    }

    @Test func removingALoginKeepsTheOrderOfTheRest() {
        var order = ListOrder([dev.id, prod.id, staging.id])

        order.remove(prod.id)

        #expect(order.ids == [dev.id, staging.id])
    }

    // MARK: Drag

    @Test func draggingALoginDownPutsItBeforeTheRowItIsDroppedOn() {
        var order = ListOrder([dev.id, prod.id, staging.id])

        order.move(fromOffsets: [0], toOffset: 2)

        #expect(order.ids == [prod.id, dev.id, staging.id])
    }

    @Test func draggingALoginToTheEndPutsItLast() {
        var order = ListOrder([dev.id, prod.id, staging.id])

        order.move(fromOffsets: [0], toOffset: 3)

        #expect(order.ids == [prod.id, staging.id, dev.id])
    }

    @Test func draggingALoginUpPutsItAtTheRowItIsDroppedOn() {
        var order = ListOrder([dev.id, prod.id, staging.id])

        order.move(fromOffsets: [2], toOffset: 0)

        #expect(order.ids == [staging.id, dev.id, prod.id])
    }

    @Test func draggingSeveralLoginsKeepsTheirOrder() {
        let qa = named("qa")
        var order = ListOrder([dev.id, prod.id, staging.id, qa.id])

        order.move(fromOffsets: [0, 2], toOffset: 4)

        #expect(order.ids == [prod.id, qa.id, dev.id, staging.id])
    }
}
