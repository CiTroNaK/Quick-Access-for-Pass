import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("Folder feature gate")
struct FolderFeatureGateTests {
    @Test("support starts unknown and a probe must confirm CLI 2.5+")
    func requiresConfirmedVersion() throws {
        let gate = FolderFeatureGate(selection: .custom(path: "/fake/a"))
        #expect(gate.availability == .checking)
        #expect(gate.supportedStamp() == nil)
        let probe = gate.beginProbe()
        gate.confirm(capabilities: .init(rawVersionString: "2.5.0"), for: probe)
        let stamp = try #require(gate.supportedStamp())
        #expect(gate.isCurrent(stamp))
        #expect(gate.availability == .supported)
    }

    @Test("new probe revokes expansion immediately")
    func probeRevokesStamp() throws {
        let gate = FolderFeatureGate(selection: .custom(path: "/fake/a"))
        gate.confirm(capabilities: .init(rawVersionString: "2.5.1"), for: gate.beginProbe())
        let stamp = try #require(gate.supportedStamp())
        _ = gate.beginProbe()
        #expect(!gate.isCurrent(stamp))
        #expect(gate.supportedStamp() == nil)
    }

    @Test("same-selection stale supported result cannot overwrite a newer denial", arguments: ["2.4.2", "invalid"])
    func newestProbeWins(newVersion: String) {
        let gate = FolderFeatureGate(selection: .custom(path: "/fake/a"))
        let old = gate.beginProbe()
        let latest = gate.beginProbe()
        gate.confirm(capabilities: .init(rawVersionString: newVersion), for: latest)
        gate.confirm(capabilities: .init(rawVersionString: "2.5.1"), for: old)
        #expect(gate.supportedStamp() == nil)
        #expect(gate.availability == (newVersion == "invalid" ? .unavailable : .requiresUpgrade))
    }

    @Test("A to B to A never accepts the original A probe")
    func selectionABA() {
        let gate = FolderFeatureGate(selection: .custom(path: "/fake/a"))
        let old = gate.beginProbe()
        #expect(gate.updateSelection(.custom(path: "/fake/b")))
        #expect(gate.updateSelection(.custom(path: "/fake/a")))
        gate.confirm(capabilities: .init(rawVersionString: "2.5.1"), for: old)
        #expect(gate.supportedStamp() == nil)
        #expect(gate.availability == .checking)
    }

    @Test("invalidation wakes an existing observer")
    func notifiesObserver() async throws {
        let gate = FolderFeatureGate(selection: .custom(path: "/fake/a"))
        var changes = gate.updates().makeAsyncIterator()
        _ = await changes.next()
        gate.confirm(capabilities: .init(rawVersionString: "2.5.1"), for: gate.beginProbe())
        _ = await changes.next()
        #expect(gate.availability == .supported)
        gate.invalidateSelection()
        _ = await changes.next()
        #expect(gate.supportedStamp() == nil)
    }
}
