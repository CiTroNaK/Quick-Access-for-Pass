import Testing
@testable import Quick_Access_for_Pass

@Suite
struct PendingLockContextTests {
    @Test
    func sshPrimaryLineUsesAppName() {
        let context = PendingLockContext.ssh(appName: "Terminal", host: nil, keySummary: nil)
        #expect(context.primaryLine == "SSH request from Terminal")
    }

    @Test
    func sshDetailUsesHostAndKeySummaryWhenPresent() {
        let context = PendingLockContext.ssh(appName: "Terminal", host: "github.com", keySummary: "SHA256:abcd")
        #expect(context.detailLine == "Host: github.com · Key: SHA256:abcd")
    }

    @Test
    func runPrimaryLineUsesAppName() {
        let context = PendingLockContext.run(appName: "Warp", profileName: "prod", commandSummary: nil)
        #expect(context.primaryLine == "Run request from Warp")
    }

    @Test
    func runDetailUsesProfileAndCommandWhenPresent() {
        let context = PendingLockContext.run(appName: "Warp", profileName: "prod", commandSummary: "deploy")
        #expect(context.detailLine == "Profile: prod · Command: deploy")
    }

    @Test
    func detailLineIsNilWhenNoDetailsExist() {
        let context = PendingLockContext.ssh(appName: "Terminal", host: nil, keySummary: nil)
        #expect(context.detailLine == nil)
    }
}
