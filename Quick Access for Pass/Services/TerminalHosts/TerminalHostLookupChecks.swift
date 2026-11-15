import Darwin
import Foundation

/// Checks shared by the Herdr and Herdr Core lookups, so a fix to one applies to both.
nonisolated enum TerminalHostLookupChecks {
    /// Throws when the caller is cancelled or the absolute deadline has passed.
    static func checkBudget(_ deadline: CLIExecutionDeadline, now: UInt64) throws {
        try Task.checkCancellation()
        _ = try deadline.remainingSeconds(at: now)
    }

    /// The requester-side chain and its host still exist unchanged (pid and start time) and remain linked child to parent.
    static func isChainIntact(_ requesterSideNodes: [RequesterProcessSnapshot.ProcessNode],
                              host: RequesterProcessSnapshot.ProcessNode,
                              readProcess: (pid_t) -> RequesterProcessSnapshot.ProcessNode?) -> Bool {
        let nodes = requesterSideNodes + [host]
        guard !requesterSideNodes.isEmpty, nodes.count <= 11, Set(nodes.map(\.pid)).count == nodes.count,
              nodes.allSatisfy({ $0.pid > 1 && $0.startTimeMicroseconds > 0 && readProcess($0.pid) == $0 }) else { return false }
        return zip(nodes, nodes.dropFirst()).allSatisfy { $0.parentPID == $1.pid }
    }

    /// An absolute path that fits `sockaddr_un` and contains no control characters.
    static func isValidSocketPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path)
            && !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
