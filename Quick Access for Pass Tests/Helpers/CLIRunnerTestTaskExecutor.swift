import Foundation

/// Keeps a native fixture's caller and default-actor hops independent of
/// unrelated synchronous test work on the cooperative pool. MainActor and
/// production CLI executors retain their own isolation and scheduling.
nonisolated final class CLIRunnerTestTaskExecutor: TaskExecutor, Sendable {
    private let queue = DispatchQueue(label: "tests.native-cli.fixture", qos: .userInitiated)

    func enqueue(_ job: UnownedJob) {
        queue.async { [self, job] in
            job.runSynchronously(on: asUnownedTaskExecutor())
        }
    }

    func asUnownedTaskExecutor() -> UnownedTaskExecutor {
        UnownedTaskExecutor(ordinary: self)
    }
}
