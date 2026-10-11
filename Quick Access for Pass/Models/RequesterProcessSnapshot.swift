import Foundation

/// Display context only; never a verified connection identity.
nonisolated struct RequesterProcessSnapshot: Equatable, Sendable {
    nonisolated struct ProcessNode: Equatable, Sendable {
        let pid: pid_t
        let parentPID: pid_t
        let startTimeMicroseconds: UInt64
        let executablePath: String
        let canonicalExecutablePath: String
    }
    let requester: ProcessNode
    let ancestors: [ProcessNode]
    let routingHints: [HerdrRoutingHint]
}

nonisolated struct HerdrRoutingHint: Equatable, Sendable {
    let socketPath: String
    let paneID: String?
    let originatingPID: pid_t
    let originatingStartTimeMicroseconds: UInt64
}

nonisolated struct TerminalHostMatch: Equatable, Sendable {
    let configurationID: String
    let executablePath: String
    let host: RequesterProcessSnapshot.ProcessNode
    let requesterSideNodes: [RequesterProcessSnapshot.ProcessNode]
    let routingHint: HerdrRoutingHint?
}
