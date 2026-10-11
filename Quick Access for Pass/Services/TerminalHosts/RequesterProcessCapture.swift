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
        for depth in 0...10 {
            let node = nodes[depth]
            if let data = readArguments(node.pid),
               let hint = decodeRoutingHint(data, pid: node.pid, startTimeMicroseconds: node.startTimeMicroseconds) {
                hints.append(hint)
            }
            guard readNode(node.pid) == node else { return nil }
            guard depth < 10, node.parentPID > 1 else { break }
            guard !nodes.contains(where: { $0.pid == node.parentPID }), let parent = readNode(node.parentPID) else { return nil }
            nodes.append(parent)
        }
        // Recheck the entire chain after capture; a process may exit/reparent while later nodes are read.
        guard nodes.allSatisfy({ readNode($0.pid) == $0 }) else { return nil }
        return .init(requester: requester, ancestors: Array(nodes.dropFirst()), routingHints: hints)
    }

    /// Parse transient procargs storage without retaining argv or unrelated environment values.
    static func decodeRoutingHint(_ data: Data, pid: pid_t, startTimeMicroseconds: UInt64) -> HerdrRoutingHint? {
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
        var socket: String?
        var pane: String?
        while offset < bytes.count {
            guard let value = field() else { return nil }
            if value.isEmpty { continue }
            // Decode only the two allowlisted fields.
            for key in ["HERDR_SOCKET_PATH=", "HERDR_PANE_ID="] {
                let prefix = Array(key.utf8)
                guard value.starts(with: prefix) else { continue }
                guard let text = String(bytes: value.dropFirst(prefix.count), encoding: .utf8), !text.isEmpty,
                      text.utf8.count <= 4096, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
                if key == "HERDR_SOCKET_PATH=" {
                    guard socket == nil, text.hasPrefix("/") else { return nil }
                    socket = text
                } else {
                    guard pane == nil else { return nil }
                    pane = text
                }
            }
        }
        guard let socket else { return nil }
        return .init(socketPath: socket, paneID: pane, originatingPID: pid, originatingStartTimeMicroseconds: startTimeMicroseconds)
    }

    static func readNode(_ pid: pid_t) -> RequesterProcessSnapshot.ProcessNode? {
        var info = proc_bsdinfo()
        let expected = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(expected)) == expected,
              info.pbi_pid == UInt32(pid), info.pbi_start_tvsec > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return .init(pid: pid, parentPID: pid_t(info.pbi_ppid), startTimeMicroseconds: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec,
                     executablePath: path, canonicalExecutablePath: URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path)
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
