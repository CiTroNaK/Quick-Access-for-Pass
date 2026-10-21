import Foundation
import Testing
@testable import Quick_Access_for_Pass

struct CLIRunnerHerdrBoundsTests {
    private func deadline(seconds: Double) -> CLIExecutionDeadline {
        .init(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000))
    }

    @Test(.timeLimit(.minutes(1))) func combinedOverloadPreservesEnvironmentAndOutputCap() async throws {
        let output = try await CLIRunner.run(executablePath: "/bin/sh", arguments: ["-c", "printf '%s' \"$QA_FIXTURE\""],
                                             environmentOverrides: ["QA_FIXTURE": "synthetic"], deadline: deadline(seconds: 3), maximumOutputBytes: 64)
        #expect(output == Data("synthetic".utf8))
        await #expect {
            try await CLIRunner.run(executablePath: "/bin/sh", arguments: ["-c", "printf '%1000s' x"],
                                    environmentOverrides: ["QA_FIXTURE": "synthetic"], deadline: deadline(seconds: 3), maximumOutputBytes: 64)
        } throws: { error in
            if case CLIError.outputLimitExceeded = error { return true }
            return false
        }
    }

    @Test(.timeLimit(.minutes(1))) func queuedExpiredOriginalDeadlineCannotLaunch() async throws {
        let gate = OfflineTestGate()
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let original = deadline(seconds: 0.05)
        let task = Task {
            try await gate.wait()
            return try await CLIRunner.run(executablePath: "/bin/sh", arguments: ["-c", "printf launched > \"$QA_MARKER\""],
                                           environmentOverrides: ["QA_MARKER": marker.path], deadline: original, maximumOutputBytes: 64)
        }
        try await gate.waitUntilEntered()
        try await Task.sleep(for: .milliseconds(100))
        await gate.open()
        await #expect { try await task.value } throws: { error in
            if case CLIError.timeout = error { return true }
            return false
        }
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
    }

    @Test(.timeLimit(.minutes(1))) func originalDeadlineIncludesOperationOwnedQueuedAdmission() async throws {
        let gate = OfflineTestGate()
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let lifecycle = CLIRunner.LifecycleTesting(suspension: { point in
            if point == .beforeExecutionStart { try? await gate.wait() }
        })
        let original = deadline(seconds: 0.1)
        let task = Task {
            try await CLIRunner.run(executablePath: "/bin/sh", arguments: ["-c", "printf launched > \"$QA_MARKER\""],
                                    environmentOverrides: ["QA_MARKER": marker.path], deadline: original,
                                    maximumOutputBytes: 64, lifecycleTesting: lifecycle)
        }
        do {
            try await gate.waitUntilEntered()
            try await Task.sleep(for: .milliseconds(200))
            await gate.open()
            await #expect { try await task.value } throws: { error in
                if case CLIError.timeout = error { return true }
                return false
            }
            #expect(FileManager.default.fileExists(atPath: marker.path) == false)
        } catch {
            task.cancel()
            await gate.open()
            _ = await task.result
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1))) func combinedOverloadCancellationCleansUpLaunchedChild() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let original = deadline(seconds: 10)
        let task = Task {
            try await CLIRunner.run(executablePath: "/bin/sh", arguments: ["-c", "printf launched > \"$QA_MARKER\"; exec /bin/sleep 60"],
                                    environmentOverrides: ["QA_MARKER": marker.path], deadline: original, maximumOutputBytes: 64)
        }
        do {
            let waitLimit = deadline(seconds: 5)
            while FileManager.default.fileExists(atPath: marker.path) == false {
                _ = try waitLimit.remainingSeconds(at: DispatchTime.now().uptimeNanoseconds)
                try await Task.sleep(for: .milliseconds(5))
            }
            let elapsed = await ContinuousClock().measure {
                task.cancel()
                await #expect(throws: CancellationError.self) { try await task.value }
            }
            #expect(elapsed < .seconds(2))
        } catch {
            task.cancel()
            _ = await task.result
            throw error
        }
    }
}
