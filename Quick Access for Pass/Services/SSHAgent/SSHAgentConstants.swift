import Foundation

nonisolated enum SSHAgentConstants {
    /// Default proxy socket path.
    static let defaultProxySocketPath = "~/.ssh/quick-access-agent.sock"

    /// Default upstream (Pass CLI) socket path.
    static let defaultUpstreamSocketPath = "~/.ssh/proton-pass-agent.sock"

    /// Maximum sun_path length in sockaddr_un (macOS). Paths must be shorter to fit a null terminator.
    static let maxSocketPathLength = 104

    /// Creates a sockaddr_un for the given path. Caller must validate path length beforehand.
    static func makeUnixAddr(path: String) -> sockaddr_un {
        assert(path.utf8.count < maxSocketPathLength, "Socket path too long for sockaddr_un")
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cstr in
                _ = memcpy(ptr, cstr, min(path.utf8.count + 1, maxSocketPathLength))
            }
        }
        return addr
    }
}
