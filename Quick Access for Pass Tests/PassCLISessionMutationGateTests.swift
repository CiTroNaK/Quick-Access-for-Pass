import Testing
@testable import Quick_Access_for_Pass

@MainActor
struct PassCLISessionMutationGateTests {
    @Test
    func contentionDoesNotQueueAndStaleReleaseCannotUnlockAnotherOwner() throws {
        let gate = PassCLISessionMutationGate()
        let first = try #require(gate.tryAcquire(.savedTokenLogin))
        #expect(gate.isBusy)
        #expect(gate.tryAcquire(.browserLogin) == nil)
        gate.release(first)
        #expect(!gate.isBusy)
        let second = try #require(gate.tryAcquire(.browserLogin))
        gate.release(first)
        #expect(gate.isBusy)
        #expect(gate.owns(second))
        #expect(!gate.owns(first))
        gate.release(second)
        #expect(!gate.isBusy)
    }

    @Test
    func foreignReleaseCannotUnlockOwner() throws {
        let gate = PassCLISessionMutationGate()
        let other = PassCLISessionMutationGate()
        let owner = try #require(gate.tryAcquire(.logout))
        let foreign = try #require(other.tryAcquire(.logout))
        gate.release(foreign)
        #expect(gate.owns(owner))
        gate.release(owner)
        other.release(foreign)
    }
}
