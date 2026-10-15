import Foundation
import Testing
@testable import Quick_Access_for_Pass

private nonisolated enum BrowserEarlyExit: CaseIterable, Sendable {
    case cancellation
    case unreadable
    case missingURL
}

private nonisolated struct DeferredBrowserRunner: CLIStreaming {
    let exit: BrowserEarlyExit
    let completionPause: OwnershipPause
    let terminationNotices: AsyncStream<Void>.Continuation

    func start(executablePath: String, arguments: [String], capturePolicy: CLIOutputCapturePolicy) throws -> CLIStreamingProcess {
        let (chunks, continuation) = AsyncThrowingStream.makeStream(of: CLIStreamChunk.self)
        switch exit {
        case .cancellation:
            break
        case .unreadable:
            continuation.yield(.stderr("Error decrypting local session"))
        case .missingURL:
            continuation.finish()
        }
        let completion = Task<CLIStreamingResult, Error> {
            await completionPause.suspend()
            continuation.finish()
            return CLIStreamingResult(terminationStatus: 1, stdout: "", stderr: "")
        }
        return CLIStreamingProcess(chunks: chunks, completion: completion, terminate: {
            terminationNotices.yield(())
            continuation.finish(throwing: CancellationError())
        })
    }
}

@MainActor
struct PassCLIBrowserProcessOwnershipTests {
    @Test(.timeLimit(.minutes(1)), arguments: BrowserEarlyExit.allCases)
    private func earlyExitKeepsAdmissionUntilNativeCompletion(exit: BrowserEarlyExit) async {
        let delegate = AppDelegate()
        let gate = delegate.passCLISessionMutationGate
        let cli = PassCLIService(cliPath: "/synthetic/pass-cli")
        let pause = OwnershipPause()
        let (notices, continuation) = AsyncStream.makeStream(of: Void.self)
        var results: [PassCLILoginResult] = []
        let browser = PassCLILoginCoordinator(
            sessionMutationGate: gate, cliService: cli, currentHealth: { .notLoggedIn },
            runner: DeferredBrowserRunner(exit: exit, completionPause: pause, terminationNotices: continuation),
            healthRefresher: OwnershipHealth(), syncTrigger: {}, resultHandler: { results.append($0) }
        )
        browser.startLogin()
        await pause.waitUntilEntered()
        if exit == .cancellation { browser.cancel() }

        // Cancellation signals once directly and again in the flow's error handler.
        // The error-handler notice resumes this MainActor test only after that
        // synchronous handler has returned; no scheduler sleeps hide early release.
        var count = 0
        for await _ in notices {
            count += 1
            if count == (exit == .cancellation ? 2 : 1) { break }
        }
        #expect(gate.isBusy)
        let native = OwnershipNativeRunner()
        let pat = PassCLIPATLoginService(
            sessionMutationGate: gate, credentialStore: OwnershipCredentials(), runner: native,
            cliService: cli, healthRefresher: OwnershipHealth(), syncTrigger: {}
        )
        #expect(await pat.loginWithSavedToken() == .busy)
        var confirmations = 0
        let secondBrowser = PassCLILoginCoordinator(
            sessionMutationGate: gate, cliService: cli, currentHealth: { .localSessionUnreadable },
            runner: OwnershipBrowserRunner(), sessionResetRunner: native,
            healthRefresher: OwnershipHealth(), syncTrigger: {}, resultHandler: { _ in }
        )
        secondBrowser.requestLogin(confirmSessionReset: { confirmations += 1; return true })
        await secondBrowser.waitForCurrentLogin()
        var logoutWasBusy = false
        do {
            try await delegate.logoutFromPassCLI(
                cliService: PassCLIService(cliPath: "/synthetic/pass-cli", runner: native), offlineModeService: nil
            )
        } catch PassCLISessionMutationGate.AdmissionError.busy {
            logoutWasBusy = true
        } catch {
            Issue.record("Unexpected logout error")
        }
        #expect(logoutWasBusy)
        #expect(confirmations == 0)
        #expect(await native.invocations.isEmpty)

        await pause.finish()
        await browser.waitForCurrentLogin()
        #expect(!gate.isBusy)
        if exit == .cancellation {
            #expect(results.isEmpty)
            #expect(browser.state == .idle)
        }
    }
}
