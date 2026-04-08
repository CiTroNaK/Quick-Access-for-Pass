import Foundation
import Darwin
@testable import Quick_Access_for_Pass

/// In-process fake SSH agent for probe tests. Binds a unix socket at a
/// unique temp path, accepts ONE connection on a background thread, reads
/// a request and writes (or doesn't write) a canned response.
///
/// Actor-isolated: `socketPath` is declared `nonisolated let` so tests can
/// read it synchronously. `serverFd` is only mutated from actor-isolated
/// `stop()`. The accept thread captures `fd` by value so it never touches
/// actor state.
actor FakeAgentListener {
    enum Mode: Sendable {
        case respondWithIdentities([IdentityEntry])
        case respondWithNoIdentities
        case neverRespond
        case closeImmediately
        case respondWithGarbage
        case acceptAndClose
    }

    struct IdentityEntry: Sendable {
        let keyBlob: Data
        let comment: String

        init(keyBlob: Data, comment: String) {
            self.keyBlob = keyBlob
            self.comment = comment
        }
    }

    nonisolated let socketPath: String
    private var serverFd: Int32 = -1

    init(mode: Mode) throws {
        let path = NSTemporaryDirectory() + "fake-agent-\(UUID().uuidString.prefix(8)).sock"
        self.socketPath = path
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FakeListenerError.socketFailed }

        var addr = SSHAgentConstants.makeUnixAddr(path: path)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else { close(fd); throw FakeListenerError.bindFailed }
        guard listen(fd, 4) == 0 else { close(fd); throw FakeListenerError.listenFailed }
        chmod(path, 0o600)
        self.serverFd = fd

        Thread.detachNewThread { [fd, mode] in
            Self.acceptLoop(serverFd: fd, mode: mode)
        }
    }

    func stop() {
        if serverFd >= 0 {
            close(serverFd)
            serverFd = -1
        }
        unlink(socketPath)
    }

    deinit {
        if serverFd >= 0 { close(serverFd) }
        unlink(socketPath)
    }

    private static func acceptLoop(serverFd: Int32, mode: Mode) {
        let clientFd = accept(serverFd, nil, nil)
        guard clientFd >= 0 else { return }
        defer { close(clientFd) }

        switch mode {
        case .closeImmediately, .acceptAndClose:
            return
        default:
            break
        }

        let handle = FileHandle(fileDescriptor: clientFd, closeOnDealloc: false)
        _ = try? SSHAgentMessage.read(from: handle)

        switch mode {
        case .closeImmediately, .acceptAndClose:
            return  // already handled above
        case .neverRespond:
            Thread.sleep(forTimeInterval: 3.0)
        case .respondWithGarbage:
            let bytes: [UInt8] = [0x00, 0x00, 0x00, 0x04, 0xDE, 0xAD, 0xBE, 0xEF]
            _ = bytes.withUnsafeBytes { write(clientFd, $0.baseAddress, $0.count) }
        case .respondWithNoIdentities:
            var payload = Data()
            payload.append(contentsOf: UInt32(0).bigEndian.bytes)
            let msg = SSHAgentMessage(type: .identitiesAnswer, payload: payload)
            try? handle.writeAll(msg.serialize())
        case .respondWithIdentities(let identities):
            var payload = Data()
            payload.append(contentsOf: UInt32(identities.count).bigEndian.bytes)
            for entry in identities {
                payload.append(contentsOf: UInt32(entry.keyBlob.count).bigEndian.bytes)
                payload.append(entry.keyBlob)
                let commentData = Data(entry.comment.utf8)
                payload.append(contentsOf: UInt32(commentData.count).bigEndian.bytes)
                payload.append(commentData)
            }
            let msg = SSHAgentMessage(type: .identitiesAnswer, payload: payload)
            try? handle.writeAll(msg.serialize())
        }
    }
}

enum FakeListenerError: Error {
    case socketFailed, bindFailed, listenFailed
}

private extension UInt32 {
    var bytes: [UInt8] {
        withUnsafeBytes(of: self) { Array($0) }
    }
}
