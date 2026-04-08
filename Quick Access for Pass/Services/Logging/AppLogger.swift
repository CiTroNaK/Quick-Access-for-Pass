import os

/// Unified logger facade.
///
/// Privacy conventions for log interpolations:
/// - `.public`: PIDs, errnos, identity counts, and raw-type enum cases /
///   state values that don't carry user data.
/// - `.private(mask: .hash)`: socket and file paths. They expand to
///   `/Users/<name>/...` and would leak the username into sysdiagnose
///   bundles if logged `.public`.
/// - Never log secrets, vault contents, or anything derived from them.
nonisolated enum AppLogger {
    private static let subsystem = "codes.petr.quick-access-for-pass"

    static let sshProxy = Logger(subsystem: subsystem, category: "ssh-proxy")
    static let sshDaemon = Logger(subsystem: subsystem, category: "ssh-daemon")
    static let runProxy = Logger(subsystem: subsystem, category: "run-proxy")
    static let coordinator = Logger(subsystem: subsystem, category: "coordinator")
    static let probe = Logger(subsystem: subsystem, category: "probe")
    static let database = Logger(subsystem: subsystem, category: "database")
    static let audit = Logger(subsystem: subsystem, category: "audit")
}
