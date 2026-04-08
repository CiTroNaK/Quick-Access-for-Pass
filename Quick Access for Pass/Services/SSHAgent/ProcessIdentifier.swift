import AppKit
import Darwin

// MARK: - Process Info

nonisolated struct SSHClientInfo: Sendable {
    let name: String
    let bundleIdentifier: String?
    let bundleURL: URL?
    /// The command line of the direct connecting process (e.g., "ssh git@github.com").
    let command: String?
    /// The user-facing command that triggered the SSH connection.
    /// For terminal commands via git/rsync/etc: the parent's command line (e.g., "git fetch --all").
    /// For direct SSH from a terminal: cleaned destination (e.g., "ssh git@github.com").
    /// For GUI apps: nil.
    let triggerCommand: String?
    /// Whether the command should be displayed in the authorization dialog.
    /// True for terminals and user-configured apps, false for GUI apps like Tower.
    let showCommand: Bool
    /// Whether the command includes `-o BatchMode=yes`, indicating a non-interactive
    /// probe that will timeout before any auth dialog can be answered.
    let batchMode: Bool

    static let unknown = SSHClientInfo(
        name: "Unknown application",
        bundleIdentifier: nil,
        bundleURL: nil,
        command: nil,
        triggerCommand: nil,
        showCommand: false,
        batchMode: false
    )
}

// MARK: - Process Identifier

nonisolated enum ProcessIdentifier {
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "net.kovidgoyal.kitty",
        "com.mitchellh.ghostty",
        "io.alacritty",
        "org.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "dev.warp.Warp-Stable",
        "com.panic.Prompt",
        "com.codinn.SecureCRT",
    ]

    private static let shellNames: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "tcsh", "csh", "login",
    ]
}

// MARK: - Public Identification API

nonisolated extension ProcessIdentifier {
    @MainActor
    static func identify(connection: VerifiedConnection) -> SSHClientInfo {
        switch connection.identity {
        case .signedApp(let bundleID, _):
            let runningApp = NSRunningApplication(processIdentifier: connection.pid)
            let command = getCommandLine(pid: connection.pid)
            let triggerCommand = makeTriggerCommand(pid: connection.pid, command: command)

            return SSHClientInfo(
                name: runningApp?.localizedName ?? bundleID,
                bundleIdentifier: bundleID,
                bundleURL: runningApp?.bundleURL,
                command: command,
                triggerCommand: triggerCommand,
                showCommand: runningApp.flatMap {
                    terminalBundleIDs.contains($0.bundleIdentifier ?? "")
                } ?? true,
                batchMode: command.map { isBatchModeCommand($0) } ?? false
            )

        case .unverified(let pid):
            let info = _identify(pid: pid)
            return SSHClientInfo(
                name: info.name,
                bundleIdentifier: "unverified.\(pid)",
                bundleURL: info.bundleURL,
                command: info.command,
                triggerCommand: info.triggerCommand,
                showCommand: info.showCommand,
                batchMode: info.batchMode
            )

        case .trustedHelper:
            assertionFailure(
                "identify(connection:) called with .trustedHelper — use identifyParent(of:)"
            )
            return .unknown
        }
    }

    @MainActor
    static func identifyParent(of connection: VerifiedConnection) -> SSHClientInfo {
        precondition(
            connection.identity == .trustedHelper,
            "identifyParent requires .trustedHelper identity"
        )
        let parentPID = getParentPID(connection.pid)
        return _identify(pid: parentPID)
    }

    @MainActor
    static func identifyRequester(of connection: VerifiedConnection) -> SSHClientInfo {
        _identify(pid: connection.pid)
    }

    /// Internal implementation — used by identify(connection:), identifyRequester(of:), and identifyParent(of:).
    @MainActor
    private static func _identify(pid: pid_t) -> SSHClientInfo {
        let command = getCommandLine(pid: pid)
        let triggerCommand = makeTriggerCommand(pid: pid, command: command)

        if let info = identifySingle(pid: pid) {
            return withCommand(info, command: command, triggerCommand: triggerCommand)
        }

        var currentPID = pid
        for _ in 0..<10 {
            let parentPID = getParentPID(currentPID)
            guard parentPID > 1, parentPID != currentPID else { break }
            currentPID = parentPID

            if let info = identifySingle(pid: currentPID) {
                return withCommand(info, command: command, triggerCommand: triggerCommand)
            }
        }

        let execName = executableName(for: pid) ?? "Unknown application"
        let isBatchMode = command.map { Self.isBatchModeCommand($0) } ?? false
        return SSHClientInfo(
            name: execName,
            bundleIdentifier: nil,
            bundleURL: nil,
            command: command,
            triggerCommand: triggerCommand,
            showCommand: true,
            batchMode: isBatchMode
        )
    }
}

// MARK: - Command Parsing

nonisolated extension ProcessIdentifier {
    private static func makeTriggerCommand(pid: pid_t, command: String?) -> String? {
        let parentPID = getParentPID(pid)
        guard parentPID > 1 else { return command.flatMap { parseDestination($0) } }

        if let parentCommand = getCommandLine(pid: parentPID) {
            let parentExec = parentCommand.split(separator: " ").first.map(String.init) ?? ""
            if !shellNames.contains(parentExec) {
                return parentCommand
            }
        }
        return command.flatMap { parseDestination($0) }
    }

    private static func withCommand(
        _ info: SSHClientInfo,
        command: String?,
        triggerCommand: String?
    ) -> SSHClientInfo {
        let shouldShow: Bool = {
            guard let bundleID = info.bundleIdentifier else { return false }
            if terminalBundleIDs.contains(bundleID) { return true }
            let json = UserDefaults.standard.string(forKey: DefaultsKey.sshShowCommandApps) ?? "[]"
            let custom = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
            return custom.contains(bundleID)
        }()

        let isBatchMode = command.map { Self.isBatchModeCommand($0) } ?? false
        return SSHClientInfo(
            name: info.name,
            bundleIdentifier: info.bundleIdentifier,
            bundleURL: info.bundleURL,
            command: command,
            triggerCommand: triggerCommand,
            showCommand: shouldShow,
            batchMode: isBatchMode
        )
    }

    static func isBatchModeCommand(_ command: String) -> Bool {
        let parts = command.split(separator: " ")
        // swiftlint:disable:next identifier_name
        for (i, part) in parts.enumerated() {
            if part.lowercased() == "-obatchmode=yes" {
                return true
            }
            if part == "-o", i + 1 < parts.count,
               parts[i + 1].lowercased() == "batchmode=yes" {
                return true
            }
        }
        return false
    }

    static func parseHost(_ command: String) -> String? {
        let parts = command.split(separator: " ").map(String.init)
        guard parts.count > 1 else { return nil }

        let flagsWithValue: Set<String> = [
            "-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J",
            "-L", "-l", "-m", "-O", "-o", "-p", "-Q", "-R", "-S", "-W", "-w",
        ]

        // swiftlint:disable:next identifier_name
        var i = 1
        while i < parts.count {
            let arg = parts[i]
            if flagsWithValue.contains(arg) {
                i += 2
            } else if arg.hasPrefix("-") {
                i += 1
            } else if !arg.contains("@") && arg.contains("=") {
                i += 1
            } else {
                if let atIndex = arg.lastIndex(of: "@") {
                    let host = String(arg[arg.index(after: atIndex)...])
                    if !host.isEmpty { return host }
                } else if arg.contains(".") {
                    return arg
                }
                i += 1
            }
        }
        return nil
    }

    static func parseDestination(_ command: String) -> String? {
        let parts = command.split(separator: " ").map(String.init)
        guard parts.count > 1 else { return nil }

        let flagsWithValue: Set<String> = [
            "-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J",
            "-L", "-l", "-m", "-O", "-o", "-p", "-Q", "-R", "-S", "-W", "-w",
        ]

        // swiftlint:disable:next identifier_name
        var i = 1
        while i < parts.count {
            let arg = parts[i]
            if flagsWithValue.contains(arg) {
                i += 2
            } else if arg.hasPrefix("-") {
                i += 1
            } else if !arg.contains("@") && arg.contains("=") {
                i += 1
            } else {
                if arg.contains("@") || arg.contains(".") {
                    let execName = (parts[0] as NSString).lastPathComponent
                    return "\(execName) \(arg)"
                }
                i += 1
            }
        }
        return nil
    }
}

// MARK: - Process Resolution

nonisolated extension ProcessIdentifier {
    @MainActor
    private static func identifySingle(pid: pid_t) -> SSHClientInfo? {
        if let app = NSRunningApplication(processIdentifier: pid) {
            let name = app.localizedName
                ?? app.executableURL?.lastPathComponent
                ?? "Unknown application"
            return SSHClientInfo(
                name: name,
                bundleIdentifier: app.bundleIdentifier,
                bundleURL: app.bundleURL,
                command: nil,
                triggerCommand: nil,
                showCommand: false,
                batchMode: false
            )
        }

        guard let path = executablePath(for: pid) else { return nil }
        return findAppBundle(for: path)
    }

    private static func getCommandLine(pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        guard sysctl(&mib, 3, buffer, &size, nil, 0) == 0 else { return nil }

        let argc = buffer.withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
        guard argc > 0 else { return nil }

        var offset = 4
        while offset < size && buffer[offset] != 0 { offset += 1 }
        while offset < size && buffer[offset] == 0 { offset += 1 }

        var args: [String] = []
        for _ in 0..<argc {
            guard offset < size else { break }
            let start = offset
            while offset < size && buffer[offset] != 0 { offset += 1 }
            let data = Data(bytes: buffer + start, count: offset - start)
            if let arg = String(data: data, encoding: .utf8) {
                if args.isEmpty {
                    args.append((arg as NSString).lastPathComponent)
                } else {
                    args.append(arg)
                }
            }
            offset += 1
        }

        return args.isEmpty ? nil : args.joined(separator: " ")
    }

    static func getParentPID(_ pid: pid_t) -> pid_t {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }

    private static func executablePath(for pid: pid_t) -> String? {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(MAXPATHLEN))
        defer { buffer.deallocate() }
        let length = proc_pidpath(pid, buffer, UInt32(MAXPATHLEN))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func executableName(for pid: pid_t) -> String? {
        guard let path = executablePath(for: pid) else { return nil }
        return (path as NSString).lastPathComponent
    }

    @MainActor
    private static func findAppBundle(for executablePath: String) -> SSHClientInfo? {
        var url = URL(fileURLWithPath: executablePath)

        while url.path != "/" {
            if url.pathExtension == "app", let bundle = Bundle(url: url) {
                let name = bundle.infoDictionary?["CFBundleName"] as? String
                    ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
                    ?? url.deletingPathExtension().lastPathComponent
                return SSHClientInfo(
                    name: name,
                    bundleIdentifier: bundle.bundleIdentifier,
                    bundleURL: url,
                    command: nil,
                    triggerCommand: nil,
                    showCommand: false,
                    batchMode: false
                )
            }
            url = url.deletingLastPathComponent()
        }

        return nil
    }
}
