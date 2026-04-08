import Testing
@testable import Quick_Access_for_Pass

@Suite("SSHAgentDaemonManager reentrancy")
struct SSHAgentDaemonManagerReentrancyTests {
    @Test(.timeLimit(.minutes(1)))
    func concurrentStartsDoNotSpawnTwice() async {
        let manager = SSHAgentDaemonManager(cliPath: "/nonexistent-cli-for-test")

        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = try? await manager.startDaemon() }
            group.addTask { _ = try? await manager.startDaemon() }
            await group.waitForAll()
        }
    }
}
