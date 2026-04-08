import Testing
@testable import Quick_Access_for_Pass

struct MenuBarHealthAggregatorTests {

    // MARK: - All healthy

    @Test("all services healthy returns normal")
    func allHealthy() {
        let result = MenuBarHealthAggregator.aggregate(
            sshHealth: .ok(detail: "3 keys"),
            runHealth: .ok(),
            cliHealth: .ok
        )
        #expect(result == .normal)
    }

    @Test("disabled proxies with healthy CLI returns normal")
    func disabledProxiesHealthyCLI() {
        let result = MenuBarHealthAggregator.aggregate(
            sshHealth: .disabled,
            runHealth: .disabled,
            cliHealth: .ok
        )
        #expect(result == .normal)
    }

    // MARK: - CLI degraded

    @Test("CLI notLoggedIn returns degraded")
    func cliNotLoggedIn() {
        let result = MenuBarHealthAggregator.aggregate(
            sshHealth: .disabled,
            runHealth: .disabled,
            cliHealth: .notLoggedIn
        )
        #expect(result == .degraded(services: ["Pass CLI"]))
    }

    // MARK: - CLI error

    @Test("CLI notInstalled returns error")
    func cliNotInstalled() {
        let result = MenuBarHealthAggregator.aggregate(
            sshHealth: .disabled,
            runHealth: .disabled,
            cliHealth: .notInstalled
        )
        #expect(result == .error(services: ["Pass CLI"]))
    }

    @Test("CLI failed returns error")
    func cliFailed() {
        let result = MenuBarHealthAggregator.aggregate(
            sshHealth: .disabled,
            runHealth: .disabled,
            cliHealth: .failed(reason: "connection reset")
        )
        #expect(result == .error(services: ["Pass CLI"]))
    }

    // MARK: - SSH states

    @Test("SSH degraded returns degraded")
    func sshDegraded() {
        let result = MenuBarHealthAggregator.aggregate(
            sshHealth: .degraded(.emptyIdentities),
            runHealth: .disabled,
            cliHealth: .ok
        )
        #expect(result == .degraded(services: ["SSH Agent"]))
    }

    @Test("SSH unreachable returns error")
    func sshUnreachable() {
        let result = MenuBarHealthAggregator.aggregate(
            sshHealth: .unreachable(.probeFailed),
            runHealth: .disabled,
            cliHealth: .ok
        )
        #expect(result == .error(services: ["SSH Agent"]))
    }

    // MARK: - Run states

    @Test("Run degraded returns degraded")
    func runDegraded() {
        let result = MenuBarHealthAggregator.aggregate(
            sshHealth: .disabled,
            runHealth: .degraded(.probeFailed),
            cliHealth: .ok
        )
        #expect(result == .degraded(services: ["Run Proxy"]))
    }

    @Test("Run unreachable returns error")
    func runUnreachable() {
        let result = MenuBarHealthAggregator.aggregate(
            sshHealth: .disabled,
            runHealth: .unreachable(.probeFailed),
            cliHealth: .ok
        )
        #expect(result == .error(services: ["Run Proxy"]))
    }

    // MARK: - Mixed: error wins over degraded

    @Test("error wins over degraded — only error services listed")
    func errorWinsOverDegraded() {
        let result = MenuBarHealthAggregator.aggregate(
            sshHealth: .degraded(.emptyIdentities),
            runHealth: .disabled,
            cliHealth: .failed(reason: "timeout")
        )
        #expect(result == .error(services: ["Pass CLI"]))
    }

    // MARK: - Multiple degraded

    @Test("multiple degraded lists all degraded services")
    func multipleDegraded() {
        let result = MenuBarHealthAggregator.aggregate(
            sshHealth: .degraded(.emptyIdentities),
            runHealth: .degraded(.probeFailed),
            cliHealth: .ok
        )
        #expect(result == .degraded(services: ["SSH Agent", "Run Proxy"]))
    }

    // MARK: - Multiple errors

    @Test("multiple errors lists all error services")
    func multipleErrors() {
        let result = MenuBarHealthAggregator.aggregate(
            sshHealth: .unreachable(.probeFailed),
            runHealth: .unreachable(.clientLoopFailure),
            cliHealth: .notInstalled
        )
        #expect(result == .error(services: ["Pass CLI", "SSH Agent", "Run Proxy"]))
    }

    // MARK: - Disabled proxies are skipped

    @Test("disabled SSH is not listed even when other services fail")
    func disabledSSHSkipped() {
        let result = MenuBarHealthAggregator.aggregate(
            sshHealth: .disabled,
            runHealth: .unreachable(.probeFailed),
            cliHealth: .ok
        )
        #expect(result == .error(services: ["Run Proxy"]))
    }
}
