import Testing
@testable import Quick_Access_for_Pass

@MainActor
private final class ConsentContext {
    var health: PassCLIHealth = .localSessionUnreadable
    var revocations = 0
}

@MainActor
struct PassCLIBrowserConsentFreshnessTests {
    private let gate = PassCLISessionMutationGate()
    private let cli = PassCLIService(cliPath: "/synthetic/pass-cli")

    private func coordinator(_ context: ConsentContext, _ reset: OwnershipNativeRunner) -> PassCLILoginCoordinator {
        PassCLILoginCoordinator(
            sessionMutationGate: gate, cliService: cli, currentHealth: { context.health },
            runner: OwnershipBrowserRunner(),
            sessionResetRunner: reset, healthRefresher: OwnershipHealth(), syncTrigger: {}, resultHandler: { _ in },
            revokeTransientSecretAccess: { context.revocations += 1 }
        )
    }

    @Test
    func healthyDuringConfirmationDoesNotReset() async {
        let context = ConsentContext()
        let reset = OwnershipNativeRunner()
        let browser = coordinator(context, reset)
        browser.requestLogin(confirmSessionReset: {
            context.health = .ok
            return true
        })
        await browser.waitForCurrentLogin()
        #expect(await reset.invocations.isEmpty)
        #expect(context.revocations == 0)
        #expect(browser.state == .idle)
        #expect(!gate.isBusy)
    }

    @Test
    func healthyBeforeQueuedStartupDoesNotReset() async {
        let context = ConsentContext()
        let reset = OwnershipNativeRunner()
        let browser = coordinator(context, reset)
        browser.requestLogin(confirmSessionReset: { true })
        context.health = .ok
        await browser.waitForCurrentLogin()
        #expect(await reset.invocations.isEmpty)
        #expect(context.revocations == 0)
        #expect(browser.state == .idle)
        #expect(!gate.isBusy)
    }

    @Test
    func selectionChangesBeforeQueuedStartupDoesNotReset() async {
        let context = ConsentContext()
        let reset = OwnershipNativeRunner()
        let browser = coordinator(context, reset)
        browser.requestLogin(confirmSessionReset: { true })
        cli.updateCLIPath("/synthetic/replacement-pass-cli")
        await browser.waitForCurrentLogin()
        #expect(await reset.invocations.isEmpty)
        #expect(context.revocations == 0)
        #expect(browser.state == .idle)
        #expect(!gate.isBusy)
    }

    @Test
    func selectionChangesDuringConfirmationDoesNotReset() async {
        let context = ConsentContext()
        let reset = OwnershipNativeRunner()
        let browser = coordinator(context, reset)
        browser.requestLogin(confirmSessionReset: {
            cli.updateCLIPath("/synthetic/replacement-pass-cli")
            return true
        })
        await browser.waitForCurrentLogin()
        #expect(await reset.invocations.isEmpty)
        #expect(context.revocations == 0)
        #expect(browser.state == .idle)
        #expect(!gate.isBusy)
    }
}
