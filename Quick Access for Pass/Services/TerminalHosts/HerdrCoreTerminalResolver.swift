import Foundation

/// A requester whose process chain runs inside a Herdr Core terminal. Display routing only; the provider
/// must still verify the holder's signature and the terminal's ownership before anything is shown.
nonisolated struct HerdrCoreTerminalMatch: Equatable, Sendable {
    let holder: RequesterProcessSnapshot.ProcessNode
    let terminalRoot: RequesterProcessSnapshot.ProcessNode
    /// Requester first, terminal root last.
    let requesterSideNodes: [RequesterProcessSnapshot.ProcessNode]
    let hint: HerdrCoreRoutingHint
    /// Topmost non-shell node below the holder; never the requester itself. Its current folder is shown.
    let programNode: RequesterProcessSnapshot.ProcessNode?
}

nonisolated enum HerdrCoreTerminalResolver {
    static let coreBundleIdentifier = "dev.herdr.core"

    /// Pure and filesystem-free, so it is safe while a header model is created on the main actor.
    static func match(clientInfo: SSHClientInfo, snapshot: RequesterProcessSnapshot?) -> HerdrCoreTerminalMatch? {
        guard clientInfo.bundleIdentifier == coreBundleIdentifier, let bundleURL = clientInfo.bundleURL,
              let snapshot else { return nil }
        // findAppBundle derived the bundle from one of these executable paths, so a string prefix suffices.
        let bundlePrefix = bundleURL.standardizedFileURL.path + "/"
        let nodes = [snapshot.requester] + snapshot.ancestors.prefix(10)
        guard let holderIndex = nodes.indices.dropFirst().first(where: { nodes[$0].executablePath.hasPrefix(bundlePrefix) })
        else { return nil }
        let holder = nodes[holderIndex]
        let root = nodes[holderIndex - 1]
        guard root.parentPID == holder.pid else { return nil }
        let below = Array(nodes.prefix(holderIndex))
        let hints = snapshot.coreRoutingHints.filter { hint in
            below.contains { $0.pid == hint.originatingPID && $0.startTimeMicroseconds == hint.originatingStartTimeMicroseconds }
        }
        guard let hint = hints.first,
              hints.allSatisfy({ $0.terminalID == hint.terminalID && $0.socketPath == hint.socketPath }) else { return nil }
        let program = below.dropFirst().reversed().first { !isShell($0) }
        return .init(holder: holder, terminalRoot: root, requesterSideNodes: below, hint: hint, programNode: program)
    }

    private static func isShell(_ node: RequesterProcessSnapshot.ProcessNode) -> Bool {
        let name = (node.executablePath as NSString).lastPathComponent
        return ProcessIdentifier.shellNames.contains(name.hasPrefix("-") ? String(name.dropFirst()) : name)
    }
}
