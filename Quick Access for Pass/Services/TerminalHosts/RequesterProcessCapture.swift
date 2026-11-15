import Foundation
import Darwin

nonisolated enum RequesterProcessCapture {
    static let maximumArgumentBytes = 256 * 1024

    /// Capture the verified helper as display context; authorization still identifies its parent.
    static func captureHelper(
        of pid: pid_t,
        readNode: (pid_t) -> RequesterProcessSnapshot.ProcessNode?,
        readArguments: (pid_t) -> Data?
    ) -> RequesterProcessSnapshot? {
        guard let helper = readNode(pid), helper.parentPID > 1,
              let snapshot = capture(pid: pid, readNode: readNode, readArguments: readArguments),
              snapshot.requester == helper,
              readNode(pid) == helper else { return nil }
        return snapshot
    }

    static func capture(
        pid: pid_t,
        readNode: (pid_t) -> RequesterProcessSnapshot.ProcessNode?,
        readArguments: (pid_t) -> Data?
    ) -> RequesterProcessSnapshot? {
        guard pid > 1, let requester = readNode(pid) else { return nil }
        var nodes = [requester]
        var hints: [HerdrRoutingHint] = []
        var coreHints: [HerdrCoreRoutingHint] = []
        for depth in 0...10 {
            let node = nodes[depth]
            if let data = readArguments(node.pid) {
                let decoded = decodeRoutingHints(data, pid: node.pid, startTimeMicroseconds: node.startTimeMicroseconds)
                if let hint = decoded.herdr { hints.append(hint) }
                if let hint = decoded.core { coreHints.append(hint) }
            }
            guard readNode(node.pid) == node else { return nil }
            guard depth < 10, node.parentPID > 1 else { break }
            guard !nodes.contains(where: { $0.pid == node.parentPID }), let parent = readNode(node.parentPID) else { return nil }
            nodes.append(parent)
        }
        // Recheck the entire chain after capture; a process may exit/reparent while later nodes are read.
        guard nodes.allSatisfy({ readNode($0.pid) == $0 }) else { return nil }
        return .init(requester: requester, ancestors: Array(nodes.dropFirst()), routingHints: hints, coreRoutingHints: coreHints)
    }

    private static let herdrKeys = ["HERDR_SOCKET_PATH=", "HERDR_PANE_ID="]
    private static let coreKeys = ["HC_TERMINAL_ID=", "HC_TERMINAL_SOCKET="]

    /// Parse transient procargs storage once for both products without retaining argv or unrelated environment
    /// values. Each product's keys are validated independently, so an invalid value for one never affects the other.
    static func decodeRoutingHints(_ data: Data, pid: pid_t, startTimeMicroseconds: UInt64)
        -> (herdr: HerdrRoutingHint?, core: HerdrCoreRoutingHint?) {
        guard let environment = allowlistedEnvironment(data, keys: herdrKeys + coreKeys) else { return (nil, nil) }
        var herdr: HerdrRoutingHint?
        if let fields = valid(environment, herdrKeys), let socket = fields["HERDR_SOCKET_PATH="], socket.hasPrefix("/") {
            herdr = .init(socketPath: socket, paneID: fields["HERDR_PANE_ID="], originatingPID: pid,
                          originatingStartTimeMicroseconds: startTimeMicroseconds)
        }
        var core: HerdrCoreRoutingHint?
        if let fields = valid(environment, coreKeys), let terminal = fields["HC_TERMINAL_ID="],
           let socket = fields["HC_TERMINAL_SOCKET="], socket.hasPrefix("/") {
            core = .init(terminalID: terminal, socketPath: socket, originatingPID: pid,
                         originatingStartTimeMicroseconds: startTimeMicroseconds)
        }
        return (herdr, core)
    }

    /// The values for `keys`, or nil when any of them was invalid or duplicated.
    private static func valid(_ environment: [String: String?], _ keys: [String]) -> [String: String]? {
        var fields: [String: String] = [:]
        for key in keys {
            guard let entry = environment[key] else { continue }
            guard let value = entry else { return nil }
            fields[key] = value
        }
        return fields
    }

    /// Walk procargs to the environment and decode only `keys`. Malformed storage returns nil; an invalid or duplicate
    /// value is recorded as `.some(nil)` so only the product owning that key rejects it.
    private static func allowlistedEnvironment(_ data: Data, keys: [String]) -> [String: String?]? {
        guard data.count >= 4, data.count <= maximumArgumentBytes else { return nil }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc <= 4096 else { return nil }
        let bytes = [UInt8](data)
        var offset = 4
        func field() -> ArraySlice<UInt8>? {
            guard offset < bytes.count, let end = bytes[offset...].firstIndex(of: 0) else { return nil }
            defer { offset = end + 1 }
            return bytes[offset..<end]
        }
        guard let executable = field(), !executable.isEmpty else { return nil }
        while offset < bytes.count && bytes[offset] == 0 { offset += 1 }
        for _ in 0..<argc { guard field() != nil else { return nil } }
        let prefixes = keys.map { ($0, Array($0.utf8)) }
        var values: [String: String?] = [:]
        while offset < bytes.count {
            guard let value = field() else { return nil }
            for (key, prefix) in prefixes where value.starts(with: prefix) {
                guard values[key] == nil,
                      let text = String(bytes: value.dropFirst(prefix.count), encoding: .utf8), !text.isEmpty,
                      text.utf8.count <= 4096,
                      !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    values[key] = .some(nil)
                    continue
                }
                values[key] = .some(text)
            }
        }
        return values
    }

    static func readNode(_ pid: pid_t) -> RequesterProcessSnapshot.ProcessNode? {
        var info = proc_bsdinfo()
        let expected = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(expected)) == expected,
              info.pbi_pid == UInt32(pid), info.pbi_start_tvsec > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return .init(pid: pid, parentPID: pid_t(info.pbi_ppid), startTimeMicroseconds: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec,
                     executablePath: path, canonicalExecutablePath: URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path)
    }

    /// Current working directory of a same-user process, or nil when it cannot be inspected.
    static func readWorkingDirectory(_ pid: pid_t) -> String? {
        guard pid > 1 else { return nil }
        var info = proc_vnodepathinfo()
        let expected = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, expected) == expected else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { buffer in
            String(bytes: buffer.prefix { $0 != 0 }, encoding: .utf8)
        }
        guard let path, path.hasPrefix("/") else { return nil }
        return path
    }

    static func readArguments(_ pid: pid_t) -> Data? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size >= 4, size <= maximumArgumentBytes else { return nil }
        var data = Data(count: size)
        let result = data.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
        guard result == 0, size >= 4, size <= data.count else { return nil }
        data.count = size
        return data
    }
}
