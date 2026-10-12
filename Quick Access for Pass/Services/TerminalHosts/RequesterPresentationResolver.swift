import Foundation

nonisolated enum RequesterPresentationResolver {
    static func resolve(
        clientInfo: SSHClientInfo,
        snapshot: RequesterProcessSnapshot?,
        entries: [TerminalHostMatchingEntry]
    ) -> (presentation: RequesterPresentation, hostMatch: TerminalHostMatch?) {
        let fallback = RequesterPresentation(name: clientInfo.name, bundleURL: clientInfo.bundleURL,
                                             symbolName: "questionmark.app", hostID: nil, details: nil)
        // Unverified transport IDs are not evidence of an identified macOS app.
        let identifiedApp = clientInfo.bundleURL != nil || (clientInfo.bundleIdentifier.map { !$0.hasPrefix("unverified.") } ?? false)
        guard !identifiedApp, let snapshot else { return (fallback, nil) }
        let nodes = [snapshot.requester] + snapshot.ancestors.prefix(10)
        for (index, node) in nodes.enumerated() {
            guard let entry = entries.first(where: {
                $0.configuration.isEnabled && $0.canonicalExecutablePath == node.canonicalExecutablePath
            }) else { continue }
            let below = Array(nodes.prefix(index))
            let hints = snapshot.routingHints.filter { hint in
                below.contains { $0.pid == hint.originatingPID && $0.startTimeMicroseconds == hint.originatingStartTimeMicroseconds }
            }
            let first = hints.first
            let coherent = hints.allSatisfy { $0.socketPath == first?.socketPath && $0.paneID == first?.paneID }
            let match = TerminalHostMatch(configurationID: entry.configuration.id, executablePath: entry.configuration.executablePath,
                                          host: node, requesterSideNodes: below, routingHint: coherent ? first : nil)
            return (.init(name: entry.configuration.displayName, bundleURL: nil, symbolName: "terminal", hostID: entry.configuration.id, details: nil), match)
        }
        return (fallback, nil)
    }
}
