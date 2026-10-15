import AppKit
import Foundation
import GRDB
import os
import Testing
@testable import Quick_Access_for_Pass

extension OfflineSecretResolverTests {
    @Test func liveOnlyResolverForwardsOriginalDeadlineForItemAndTOTP() async throws {
        let runner = LiveOnlyDeadlineRunner()
        let resolver = LiveSecretItemResolver(cliService: PassCLIService(cliPath: "/fake/pass-cli", runner: runner))
        let deadline = CLIExecutionDeadline(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 10_000_000_000)
        let context = SecretResolutionContext(deadlineUptimeNanoseconds: deadline.uptimeNanoseconds, expectedUsername: nil)
        await #expect(throws: CLIError.self) {
            _ = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share", context: context)
        }
        await #expect(throws: CLIError.self) {
            _ = try await resolver.resolveTOTP(itemId: "item", vaultId: "vault", shareId: "share", context: context)
        }
        #expect(await runner.observedDeadlines() == [deadline, deadline])
        #expect(await runner.relativeCallCount() == 0)
    }

    @Test func liveOnlyCombinedAutoFillDelegatesBothCommandsWithOriginalDeadline() async throws {
        let runner = LiveOnlyComposedDeadlineRunner()
        let resolver = LiveSecretItemResolver(cliService: PassCLIService(cliPath: "/fake/pass-cli", runner: runner))
        let deadline = CLIExecutionDeadline(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 10_000_000_000)
        let context = SecretResolutionContext(deadlineUptimeNanoseconds: deadline.uptimeNanoseconds, expectedUsername: "person@example.test")

        let result = try await resolver.resolveAutoFillValue(
            itemId: "item", vaultId: "vault", shareId: "share", kind: .oneTimeCode, context: context
        )
        #expect(result.value == "246810")
        #expect(result.offlineCapability == nil)
        #expect(await runner.observedDeadlines() == [deadline, deadline])
    }

    @Test func liveOnlyResolverRejectsExpiredItemAndTOTPDeadlinesBeforeRunner() async throws {
        let runner = LiveOnlyDeadlineRunner()
        let resolver = LiveSecretItemResolver(cliService: PassCLIService(cliPath: "/fake/pass-cli", runner: runner))
        let context = SecretResolutionContext(deadlineUptimeNanoseconds: 0, expectedUsername: nil)
        await #expect(throws: SecretResolutionError.deadlineExpired) {
            _ = try await resolver.resolveItem(itemId: "item", vaultId: "vault", shareId: "share", context: context)
        }
        await #expect(throws: SecretResolutionError.deadlineExpired) {
            _ = try await resolver.resolveTOTP(itemId: "item", vaultId: "vault", shareId: "share", context: context)
        }
        #expect(await runner.observedDeadlines().isEmpty)
        #expect(await runner.relativeCallCount() == 0)
    }
}

private actor LiveOnlyComposedDeadlineRunner: CLIRunning {
    private var deadlines: [CLIExecutionDeadline] = []

    func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> Data { throw CLIError.timeout }
    func run(executablePath: String, arguments: [String], timeout: TimeInterval, maximumOutputBytes: Int) async throws -> Data { throw CLIError.timeout }
    func run(executablePath: String, arguments: [String], deadline: CLIExecutionDeadline, maximumOutputBytes: Int) async throws -> Data {
        deadlines.append(deadline)
        if arguments.contains("totp") {
            return Data("{\"totp_uri\":\"otpauth://redacted\",\"totp\":\"246810\"}".utf8)
        }
        return Data("""
        {
          "item": {
            "id": "item", "share_id": "share", "vault_id": "vault",
            "content": {
              "title": "Fixture", "note": "", "item_uuid": "fixture",
              "content": {
                "Login": {
                  "username": "person@example.test", "email": "", "password": "not-released",
                  "totp_uri": "otpauth://totp/Test?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", "urls": []
                }
              },
              "extra_fields": []
            },
            "state": "Active", "flags": [], "create_time": "", "modify_time": ""
          }
        }
        """.utf8)
    }
    func observedDeadlines() -> [CLIExecutionDeadline] { deadlines }
}

private actor LiveOnlyDeadlineRunner: CLIRunning {
    private var deadlines: [CLIExecutionDeadline] = []
    private var relativeCalls = 0

    func run(executablePath: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        relativeCalls += 1
        throw CLIError.notLoggedIn
    }

    func run(executablePath: String, arguments: [String], timeout: TimeInterval, maximumOutputBytes: Int) async throws -> Data {
        relativeCalls += 1
        throw CLIError.notLoggedIn
    }

    func run(executablePath: String, arguments: [String], deadline: CLIExecutionDeadline, maximumOutputBytes: Int) async throws -> Data {
        deadlines.append(deadline)
        throw CLIError.notLoggedIn
    }

    func observedDeadlines() -> [CLIExecutionDeadline] { deadlines }
    func relativeCallCount() -> Int { relativeCalls }
}
