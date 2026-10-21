import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite struct RequesterProcessSnapshotTests {
    private func args(_ fields: [String], argc: Int32 = 1) -> Data {
        var count = argc
        var result = withUnsafeBytes(of: &count) { Data($0) }
        result.append(Data("/bin/synthetic\0\0".utf8))
        for field in fields { result.append(Data(field.utf8)); result.append(0) }
        return result
    }
    @Test func decoderCollectsOnlyNamedHints() {
        let data = args(["synthetic", "OTHER=ignored", "HERDR_SOCKET_PATH=/tmp/synthetic.sock", "HERDR_PANE_ID=pane", "UNRELATED=value", ""])
        let hint = RequesterProcessCapture.decodeRoutingHint(data, pid: 10, startTimeMicroseconds: 20)
        #expect(hint == .init(socketPath: "/tmp/synthetic.sock", paneID: "pane", originatingPID: 10, originatingStartTimeMicroseconds: 20))
        #expect(RequesterProcessCapture.decodeRoutingHint(args(["synthetic", "HERDR_PANE_ID=pane", ""]), pid: 10, startTimeMicroseconds: 20) == nil)
    }
    @Test func malformedTruncatedAndOversizedArgsFailClosed() {
        for data in [Data(), Data([1, 0, 0]), args(["synthetic"], argc: -1), args(["synthetic"], argc: 100),
                     Data(repeating: 1, count: 262145),
                     args(["synthetic", "HERDR_SOCKET_PATH=/tmp/a", "HERDR_SOCKET_PATH=/tmp/b", ""]),
                     args(["synthetic", "HERDR_SOCKET_PATH=relative", ""])] {
            #expect(RequesterProcessCapture.decodeRoutingHint(data, pid: 10, startTimeMicroseconds: 20) == nil)
        }
        var truncated = args(["synthetic", "HERDR_SOCKET_PATH=/tmp/socket"])
        truncated.removeLast()
        #expect(RequesterProcessCapture.decodeRoutingHint(truncated, pid: 10, startTimeMicroseconds: 20) == nil)
    }
    @Test func helperOnlyRoutingHintsReachMatchedHost() throws {
        let read: (Int32) -> RequesterProcessSnapshot.ProcessNode? = { pid in
            switch pid {
            case 10: .init(pid: 10, parentPID: 20, startTimeMicroseconds: 10, executablePath: "/fixture/qa-run", canonicalExecutablePath: "/fixture/qa-run")
            case 20: .init(pid: 20, parentPID: 30, startTimeMicroseconds: 20, executablePath: "/bin/zsh", canonicalExecutablePath: "/bin/zsh")
            case 30: .init(pid: 30, parentPID: 1, startTimeMicroseconds: 30, executablePath: "/fixture/herdr", canonicalExecutablePath: "/fixture/herdr")
            default: nil
            }
        }
        let helperArgs = args(["qa-run", "HERDR_SOCKET_PATH=/tmp/synthetic.sock", "HERDR_PANE_ID=pane", ""])
        let snapshot = try #require(RequesterProcessCapture.captureHelper(of: 10, readNode: read,
                                                                         readArguments: { $0 == 10 ? helperArgs : nil }))
        let entry = TerminalHostConfiguration(id: "herdr", executablePath: "/fixture/herdr", displayName: "Herdr",
                                             isEnabled: true, provider: .herdr, showPaneDetails: true, isAutomaticallyDetected: true)
        let resolved = RequesterPresentationResolver.resolve(clientInfo: .unknown, snapshot: snapshot,
            entries: [.init(configuration: entry, canonicalExecutablePath: "/fixture/herdr")])
        let match = try #require(resolved.hostMatch)
        #expect(match.routingHint?.socketPath == "/tmp/synthetic.sock")
        #expect(match.routingHint?.originatingPID == 10)
        #expect(match.requesterSideNodes.map(\.pid) == [10, 20])
        #expect(snapshot.requester.pid == 10)
        var helperReads = 0
        let recycled = RequesterProcessCapture.captureHelper(of: 10, readNode: { pid in
            guard let node = read(pid) else { return nil }
            if pid != 10 { return node }
            helperReads += 1
            return .init(pid: node.pid, parentPID: node.parentPID, startTimeMicroseconds: helperReads == 1 ? 10 : 11,
                         executablePath: node.executablePath, canonicalExecutablePath: node.canonicalExecutablePath)
        }, readArguments: { $0 == 10 ? helperArgs : nil })
        #expect(recycled == nil)
    }

    @Test func depthExitRecyclingAndParentAttribution() {
        let read: (Int32) -> RequesterProcessSnapshot.ProcessNode? = { pid in
            .init(pid: pid, parentPID: pid + 1, startTimeMicroseconds: UInt64(pid), executablePath: "/bin/synthetic", canonicalExecutablePath: "/bin/synthetic")
        }
        let snapshot = RequesterProcessCapture.capture(pid: 10, readNode: read, readArguments: { _ in nil })
        #expect(snapshot?.requester.pid == 10)
        #expect(snapshot?.ancestors.count == 10)
        #expect(RequesterProcessCapture.capture(pid: 10, readNode: { _ in nil }, readArguments: { _ in nil }) == nil)
        #expect(RequesterProcessCapture.capture(pid: 10, readNode: { pid in pid == 11 ? nil : read(pid) }, readArguments: { _ in nil }) == nil)
        #expect(RequesterProcessCapture.capture(pid: 10, readNode: { pid in
            .init(pid: pid, parentPID: pid, startTimeMicroseconds: 1, executablePath: "/bin/synthetic", canonicalExecutablePath: "/bin/synthetic")
        }, readArguments: { _ in nil }) == nil)
        var requesterReads = 0
        #expect(RequesterProcessCapture.capture(pid: 10, readNode: { pid in
            if pid == 10 {
                requesterReads += 1
                if requesterReads > 2 { return nil }
            }
            return read(pid)
        }, readArguments: { _ in nil }) == nil)
        var reads = 0
        let recycled = RequesterProcessCapture.capture(pid: 10, readNode: { pid in
            reads += 1
            let node = read(pid)!
            return .init(pid: pid, parentPID: node.parentPID, startTimeMicroseconds: UInt64(reads), executablePath: node.executablePath, canonicalExecutablePath: node.canonicalExecutablePath)
        }, readArguments: { _ in nil })
        #expect(recycled == nil)
        // Display context includes the helper; app/authorization identity is still derived from its parent.
        let helperSnapshot = RequesterProcessCapture.captureHelper(of: 9, readNode: read, readArguments: { _ in nil })
        #expect(helperSnapshot?.requester.pid == 9)
        #expect(helperSnapshot?.requester.parentPID == 10)
        #expect(helperSnapshot?.ancestors.count == 10)
    }
}
