import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("Offline secret deadline queue", .timeLimit(.minutes(1)))
struct OfflineSecretResolverDeadlineQueueTests {
    @Test(.timeLimit(.minutes(1)))
    func passCLISecretRequestsKeepOriginalDeadlineThroughRunnerQueue() async throws {
        let runner = DeadlineQueueCLIRunner()
        let service = PassCLIService(cliPath: "/fake/pass-cli", runner: runner)
        let deadline = CLIExecutionDeadline(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 10_000_000_000)
        let item = Task { try await service.viewItem(itemId: "item", shareId: "share", deadline: deadline) }
        var totp: Task<String, any Error>?
        var settlementMonitor: Task<Void, Never>?
        var timeoutMonitor: Task<Void, Never>?
        do {
            try await runner.waitUntilFirstEntered()
            let queuedTotp = Task<String, any Error> {
                try await service.getTotp(itemId: "item", shareId: "share", deadline: deadline)
            }
            totp = queuedTotp
            try await runner.waitUntilSecondQueued()

            let settled = TestOutcomeLatch()
            settlementMonitor = Task {
                _ = await item.result
                _ = await queuedTotp.result
                await settled.resolve(true)
            }
            timeoutMonitor = Task {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                await settled.resolve(false)
            }
            await runner.openGate()
            let bothSettled = await settled.value()
            timeoutMonitor?.cancel()
            if let timeoutMonitor { await timeoutMonitor.value }
            guard bothSettled else {
                item.cancel()
                queuedTotp.cancel()
                await runner.openGate()
                _ = await item.result
                _ = await queuedTotp.result
                if let settlementMonitor { await settlementMonitor.value }
                Issue.record("queued CLI requests did not both settle within the bounded wait")
                return
            }
            if let settlementMonitor { await settlementMonitor.value }
            await #expect(throws: CLIError.self) { try await item.value }
            await #expect(throws: CLIError.self) { try await queuedTotp.value }
            #expect(await runner.deadlines() == [deadline, deadline])
        } catch {
            item.cancel()
            totp?.cancel()
            await runner.openGate()
            _ = await item.result
            if let totp { _ = await totp.result }
            timeoutMonitor?.cancel()
            if let timeoutMonitor { await timeoutMonitor.value }
            if let settlementMonitor { await settlementMonitor.value }
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func deadlineQueueSettlesWhenFirstRequestIsCancelled() async throws {
        let runner = DeadlineQueueCLIRunner()
        let service = PassCLIService(cliPath: "/fake/pass-cli", runner: runner)
        let deadline = CLIExecutionDeadline(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 10_000_000_000)
        let first = Task { try await service.viewItem(itemId: "item", shareId: "share", deadline: deadline) }
        var second: Task<String, any Error>?
        var firstSettlementMonitor: Task<Void, Never>?
        var secondSettlementMonitor: Task<Void, Never>?
        var timeoutMonitor: Task<Void, Never>?
        do {
            try await runner.waitUntilFirstEntered()
            let queuedSecond = Task<String, any Error> {
                try await service.getTotp(itemId: "item", shareId: "share", deadline: deadline)
            }
            second = queuedSecond
            try await runner.waitUntilSecondQueued()

            let firstSettled = TestOutcomeLatch()
            firstSettlementMonitor = Task {
                _ = await first.result
                await firstSettled.resolve(true)
            }
            timeoutMonitor = Task {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                await firstSettled.resolve(false)
            }
            first.cancel()
            let firstDidSettle = await firstSettled.value()
            timeoutMonitor?.cancel()
            if let timeoutMonitor { await timeoutMonitor.value }
            guard firstDidSettle else {
                first.cancel()
                queuedSecond.cancel()
                await runner.openGate()
                _ = await first.result
                _ = await queuedSecond.result
                if let firstSettlementMonitor { await firstSettlementMonitor.value }
                Issue.record("cancelled admitted owner did not settle within the bounded wait")
                return
            }
            if let firstSettlementMonitor { await firstSettlementMonitor.value }
            await #expect(throws: CancellationError.self) { try await first.value }

            await runner.openGate()
            let secondSettled = TestOutcomeLatch()
            secondSettlementMonitor = Task {
                _ = await queuedSecond.result
                await secondSettled.resolve(true)
            }
            timeoutMonitor = Task {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                await secondSettled.resolve(false)
            }
            let secondDidSettle = await secondSettled.value()
            timeoutMonitor?.cancel()
            if let timeoutMonitor { await timeoutMonitor.value }
            guard secondDidSettle else {
                queuedSecond.cancel()
                await runner.openGate()
                _ = await queuedSecond.result
                if let secondSettlementMonitor { await secondSettlementMonitor.value }
                Issue.record("queued request did not settle after admitted owner cancellation")
                return
            }
            if let secondSettlementMonitor { await secondSettlementMonitor.value }
            await #expect(throws: CLIError.self) { try await queuedSecond.value }
            #expect(await runner.deadlines() == [deadline, deadline])
        } catch {
            first.cancel()
            second?.cancel()
            await runner.openGate()
            _ = await first.result
            if let second { _ = await second.result }
            timeoutMonitor?.cancel()
            if let timeoutMonitor { await timeoutMonitor.value }
            if let firstSettlementMonitor { await firstSettlementMonitor.value }
            if let secondSettlementMonitor { await secondSettlementMonitor.value }
            throw error
        }
    }
}

private actor DeadlineQueueCLIRunner: CLIRunning {
    private struct QueuedPermit {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let gate = OfflineTestGate()
    private var active = false
    private let queueGate = OfflineTestGate()
    private var queuedPermits: [QueuedPermit] = []
    private var observedDeadlines: [CLIExecutionDeadline] = []

    func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> Data { Data("{}".utf8) }
    func run(executablePath: String, arguments: [String], timeout: TimeInterval, maximumOutputBytes: Int) async throws -> Data { Data("{}".utf8) }

    func run(executablePath: String, arguments: [String], deadline: CLIExecutionDeadline, maximumOutputBytes: Int) async throws -> Data {
        try await acquirePermit()
        defer { releasePermit() }
        observedDeadlines.append(deadline)
        try await gate.wait()
        return Data("not-json".utf8)
    }

    private func acquirePermit() async throws {
        guard active else {
            active = true
            return
        }

        let id = UUID()
        let queueGate = self.queueGate
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    queuedPermits.append(QueuedPermit(id: id, continuation: continuation))
                    Task { try? await queueGate.wait() }
                }
            }
        } onCancel: {
            Task { await self.cancelQueuedPermit(id) }
        }

        if Task.isCancelled {
            releasePermit()
            throw CancellationError()
        }
    }

    private func cancelQueuedPermit(_ id: UUID) {
        guard let index = queuedPermits.firstIndex(where: { $0.id == id }) else { return }
        queuedPermits.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func releasePermit() {
        if !queuedPermits.isEmpty {
            queuedPermits.removeFirst().continuation.resume()
        } else {
            active = false
        }
    }

    func waitUntilFirstEntered() async throws { try await gate.waitUntilEntered() }
    func waitUntilSecondQueued() async throws { try await queueGate.waitUntilEntered() }
    func openGate() async {
        await gate.open()
        await queueGate.open()
    }
    func deadlines() -> [CLIExecutionDeadline] { observedDeadlines }
}

private actor TestOutcomeLatch {
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func value() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { continuation = $0 }
    }

    func resolve(_ result: Bool) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(returning: result)
        continuation = nil
    }
}
