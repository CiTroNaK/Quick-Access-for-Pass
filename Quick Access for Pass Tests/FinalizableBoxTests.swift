import Testing
import Foundation
@testable import Quick_Access_for_Pass

struct FinalizableBoxTests {

    @Test func initialValueReadable() {
        let box = FinalizableBox<Int>(initial: 1)
        #expect(box.value == 1)
    }

    @Test func setIfNotFinalizedTakesEffect() {
        let box = FinalizableBox<Int>(initial: 1)
        box.setIfNotFinalized(2)
        #expect(box.value == 2)
    }

    @Test func finalizeBlocksLaterWrites() {
        let box = FinalizableBox<Int>(initial: 1)
        _ = box.finalize(99)
        box.setIfNotFinalized(2)
        #expect(box.value == 99, "setIfNotFinalized after finalize must drop")
    }

    @Test func finalizeReturnsTheFinalValue() {
        let box = FinalizableBox<Int>(initial: 1)
        let result = box.finalize(42)
        #expect(result == 42)
    }

    @Test func lateWriteFromAnotherTaskIsDroppedAfterFinalize() async {
        let box = FinalizableBox<Int>(initial: 0)
        let task = Task {
            try? await Task.sleep(for: .milliseconds(50))
            box.setIfNotFinalized(999)
        }
        _ = box.finalize(-1)
        await task.value
        #expect(box.value == -1, "finalize must win over a late write")
    }
}
