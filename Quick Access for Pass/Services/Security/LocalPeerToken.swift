import Darwin

/// The audit token of the process at the other end of a connected local socket. Host-only: the AutoFill extension
/// keeps its own equivalent in `AutoFillPeerVerifier` so its pinned source boundary stays unchanged.
nonisolated enum LocalPeerToken {
    /// nil when the kernel does not return a complete token; a partial token must never be validated.
    static func read(fd: Int32) -> audit_token_t? {
        var token = audit_token_t()
        var tokenSize = socklen_t(MemoryLayout<audit_token_t>.size)
        let status = withUnsafeMutablePointer(to: &token) { pointer in
            getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, pointer, &tokenSize)
        }
        guard status == 0, tokenSize == MemoryLayout<audit_token_t>.size else { return nil }
        return token
    }
}
