import Darwin
import Foundation

nonisolated enum RunSecretResolver {
    static func resolve(
        mappings: [RunProfileEnvMapping],
        cliPath: String
    ) async throws -> [String: String] {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("qa-resolve-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        chmod(tempDirectory.path, 0o700)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let envFile = tempDirectory.appendingPathComponent("refs.env")
        let outputPipe = tempDirectory.appendingPathComponent("resolved.pipe")
        let envNames = Set(mappings.map(\.envVariable))
        let orderedEnvNames = envNames.sorted()
        let content = mappings
            .map { "\($0.envVariable)=\($0.secretReference)" }
            .joined(separator: "\n")
        try content.write(to: envFile, atomically: true, encoding: .utf8)
        chmod(envFile.path, 0o600)
        guard mkfifo(outputPipe.path, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var outputChannel = try FIFOOutputChannel.open(path: outputPipe.path)
        let outputTask = outputChannel.startReading()
        defer { outputChannel.close() }

        do {
            _ = try await CLIRunner.run(
                executablePath: cliPath,
                arguments: [
                    "run",
                    "--env-file",
                    envFile.path,
                    "--",
                    envExportHelperPath(),
                    outputPipe.path
                ] + orderedEnvNames,
                timeout: 30
            )
        } catch {
            outputChannel.closeKeepAliveWriter()
            _ = try? await outputTask.value
            throw error
        }

        outputChannel.closeKeepAliveWriter()
        let data = try await outputTask.value
        guard let output = String(data: data, encoding: .utf8) else { return [:] }
        return parseEnvOutput(output, keys: envNames)
    }

    private static func envExportHelperPath() -> String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/qa-env-export")
            .path
    }

    private struct FIFOOutputChannel {
        private var readFD: Int32
        private var keepAliveWriteFD: Int32

        static func open(path: String) throws -> Self {
            let readFD = Darwin.open(path, O_RDONLY | O_NONBLOCK)
            guard readFD >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }

            let keepAliveWriteFD = Darwin.open(path, O_WRONLY | O_NONBLOCK)
            guard keepAliveWriteFD >= 0 else {
                Darwin.close(readFD)
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }

            return Self(readFD: readFD, keepAliveWriteFD: keepAliveWriteFD)
        }

        mutating func startReading() -> Task<Data, Error> {
            let fd = readFD
            readFD = -1
            return Task {
                defer { Darwin.close(fd) }
                return try Self.readToEnd(from: fd)
            }
        }

        mutating func close() {
            closeKeepAliveWriter()
            if readFD >= 0 {
                Darwin.close(readFD)
                readFD = -1
            }
        }

        mutating func closeKeepAliveWriter() {
            if keepAliveWriteFD >= 0 {
                Darwin.close(keepAliveWriteFD)
                keepAliveWriteFD = -1
            }
        }

        private static func readToEnd(from fd: Int32) throws -> Data {
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 {
                    data.append(buffer, count: count)
                } else if count == 0 {
                    return data
                } else if errno == EINTR {
                    continue
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    usleep(1_000)
                } else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
    }

    /// Parse environment-export output into a `[String: String]`, filtered to
    /// include only keys present in `keys`. Supports legacy newline-delimited
    /// `/usr/bin/env` output and the NUL-delimited private helper output.
    /// Handles values that contain `=` by splitting on the first occurrence
    /// only. Records without any `=` are skipped silently. Empty values are
    /// preserved as empty strings.
    static func parseEnvOutput(_ output: String, keys: Set<String>) -> [String: String] {
        var resolved: [String: String] = [:]
        let separator: Character = output.contains("\0") ? "\0" : "\n"
        for record in output.split(separator: separator, omittingEmptySubsequences: false) {
            guard let eqIdx = record.firstIndex(of: "=") else { continue }
            let key = String(record[record.startIndex..<eqIdx])
            let value = String(record[record.index(after: eqIdx)...])
            if keys.contains(key) {
                resolved[key] = value
            }
        }
        return resolved
    }
}
