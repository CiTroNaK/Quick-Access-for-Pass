import Foundation

/// Bounds expensive synchronous fixture construction, not test-body concurrency.
/// In particular, simultaneous SQLCipher migrations must not monopolize the
/// cooperative pool or starve independent native deadline fixtures.
nonisolated final class FixtureSetupExecutor: TaskExecutor, Sendable {
    static let shared = FixtureSetupExecutor()
    private let queue: OperationQueue

    private init() {
        let queue = OperationQueue()
        queue.name = "tests.fixture-setup"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        self.queue = queue
    }

    func enqueue(_ job: UnownedJob) {
        queue.addOperation { [self, job] in
            job.runSynchronously(on: asUnownedTaskExecutor())
        }
    }

    func asUnownedTaskExecutor() -> UnownedTaskExecutor {
        UnownedTaskExecutor(ordinary: self)
    }
}
