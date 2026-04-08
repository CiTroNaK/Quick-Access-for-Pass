import Foundation

// MARK: - Wire Protocol (duplicated from main app — no shared framework)

struct RunProxyRequest: Codable {
    let profile: String
    let command: [String]
    let pid: Int32
}

enum RunProxyDecision: String, Codable {
    case allow
    case deny
}

struct RunProxyResponse: Codable {
    let decision: RunProxyDecision
    let env: [String: String]?
}

enum Wire {
    static func writeMessage<T: Encodable>(_ value: T, to fd: Int32) throws {
        let data = try JSONEncoder().encode(value)
        var length = UInt32(data.count).bigEndian
        let lengthData = Data(bytes: &length, count: 4)
        try writeAll(fd: fd, data: lengthData)
        try writeAll(fd: fd, data: data)
    }

    static func readMessage<T: Decodable>(_ type: T.Type, from fd: Int32) throws -> T {
        let lengthData = try readExact(fd: fd, count: 4)
        let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard length > 0 && length < 1_000_000 else { exit(1) }
        let jsonData = try readExact(fd: fd, count: Int(length))
        return try JSONDecoder().decode(T.self, from: jsonData)
    }

    private static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                guard written > 0 else { throw NSError(domain: "qa-run", code: 1) }
                offset += written
            }
        }
    }

    private static func readExact(fd: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { buffer in
            while offset < count {
                let n = Darwin.read(fd, buffer.baseAddress! + offset, count - offset)
                guard n > 0 else { throw NSError(domain: "qa-run", code: 1) }
                offset += n
            }
        }
        return data
    }
}

// MARK: - PATH Lookup

func findInPath(_ name: String) -> String? {
    guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
    for dir in path.split(separator: ":") {
        let full = "\(dir)/\(name)"
        if FileManager.default.isExecutableFile(atPath: full) {
            return full
        }
    }
    return nil
}

// MARK: - Signal Forwarding

nonisolated(unsafe) var gChildPid: pid_t = 0

// MARK: - Main

func main() -> Int32 {
    let args = CommandLine.arguments

    // Parse --profile <slug> -- <command...>
    guard let profileIdx = args.firstIndex(of: "--profile"),
          profileIdx + 1 < args.count else {
        fputs("Usage: qa-run --profile <slug> -- <command> [args...]\n", stderr)
        return 1
    }
    let profileSlug = args[profileIdx + 1]

    guard let separatorIdx = args.firstIndex(of: "--"), separatorIdx > profileIdx + 1 else {
        fputs("Usage: qa-run --profile <slug> -- <command> [args...]\n", stderr)
        return 1
    }
    let command = Array(args[(separatorIdx + 1)...])
    guard !command.isEmpty else {
        fputs("Usage: qa-run --profile <slug> -- <command> [args...]\n", stderr)
        return 1
    }

    // Connect to socket
    let socketPath = NSString(string: "~/.local/share/quick-access/run.sock").expandingTildeInPath

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        fputs("Error: Quick Access for Pass is not running\n", stderr)
        return 1
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        socketPath.withCString { cstr in
            _ = memcpy(ptr, cstr, min(socketPath.utf8.count + 1, 104))
        }
    }

    let connectResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connectResult == 0 else {
        close(fd)
        fputs("Error: Quick Access for Pass is not running\n", stderr)
        return 1
    }

    // Send request
    let request = RunProxyRequest(profile: profileSlug, command: command, pid: getpid())
    do {
        try Wire.writeMessage(request, to: fd)
    } catch {
        close(fd)
        fputs("Error: failed to send request\n", stderr)
        return 1
    }

    // Wait for response
    let response: RunProxyResponse
    do {
        response = try Wire.readMessage(RunProxyResponse.self, from: fd)
    } catch {
        close(fd)
        fputs("Error: failed to read response\n", stderr)
        return 1
    }
    close(fd)

    guard response.decision == .allow, let env = response.env else {
        fputs("Authorization denied by Quick Access for Pass\n", stderr)
        return 1
    }

    // Build environment array explicitly (merge injected vars into current env)
    var envDict = ProcessInfo.processInfo.environment
    for (key, value) in env {
        envDict[key] = value
    }
    let cEnv: [UnsafeMutablePointer<CChar>?] = envDict.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { for case let e? in cEnv { free(e) } }

    // Find the command executable
    let execPath: String
    if command[0].contains("/") {
        execPath = command[0]
    } else {
        guard let found = findInPath(command[0]) else {
            fputs("Error: \(command[0]) not found in PATH\n", stderr)
            return 1
        }
        execPath = found
    }

    // Spawn the command directly (no pass-cli run needed)
    let cArgs: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]
    defer { for case let arg? in cArgs { free(arg) } }

    var childPid: pid_t = 0
    let spawnResult = posix_spawn(&childPid, execPath, nil, nil, cArgs, cEnv)
    guard spawnResult == 0 else {
        fputs("Error: failed to spawn \(command[0]) (errno \(spawnResult))\n", stderr)
        return 1
    }

    // Forward SIGTERM to child process
    gChildPid = childPid
    signal(SIGTERM) { _ in
        kill(gChildPid, SIGTERM)
    }

    // Wait for child
    var status: Int32 = 0
    waitpid(childPid, &status, 0)

    // Extract exit status: WIFEXITED/WEXITSTATUS macros aren't available in Swift
    if (status & 0x7F) == 0 {
        return (status >> 8) & 0xFF
    }
    return 1
}

exit(main())
