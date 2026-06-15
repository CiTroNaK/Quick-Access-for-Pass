import Foundation
import os

nonisolated enum CLIStreamChunk: Sendable, Equatable {
    case stdout(String)
    case stderr(String)
}

nonisolated enum CLIOutputCapturePolicy: Sendable {
    case raw
    case redacted(@Sendable (String) -> String)

    func capture(_ text: String) -> String {
        switch self {
        case .raw: text
        case .redacted(let redact): redact(text)
        }
    }
}

nonisolated struct CLIStreamingResult: Sendable, Equatable {
    let terminationStatus: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { terminationStatus == 0 }
}

nonisolated struct CLIStreamingProcess: Sendable {
    let chunks: AsyncThrowingStream<CLIStreamChunk, Error>
    let completion: Task<CLIStreamingResult, Error>
    let terminate: @Sendable () -> Void
}

protocol CLIStreaming: Sendable {
    nonisolated func start(
        executablePath: String,
        arguments: [String],
        capturePolicy: CLIOutputCapturePolicy
    ) throws -> CLIStreamingProcess
}

nonisolated struct LiveCLIStreamingRunner: CLIStreaming {
    nonisolated func start(
        executablePath: String,
        arguments: [String],
        capturePolicy: CLIOutputCapturePolicy = .raw
    ) throws -> CLIStreamingProcess {
        let process = Self.makeProcess(executablePath: executablePath, arguments: arguments)
        let pipes = StreamingPipes()
        pipes.attach(to: process)

        let state = StreamingProcessState(process: process, capturePolicy: capturePolicy)
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: CLIStreamChunk.self,
            bufferingPolicy: .bufferingNewest(100)
        )
        let readerContext = StreamingReaderContext(continuation: continuation)

        Self.installTerminationHandler(on: process, state: state, completionGroup: readerContext.completionGroup)
        try Self.run(process, pipes: pipes, continuation: continuation)
        Self.startReaders(pipes: pipes, context: readerContext, state: state)

        let completion = Self.makeCompletionTask(state: state, context: readerContext)
        return CLIStreamingProcess(chunks: stream, completion: completion, terminate: { state.terminate() })
    }

    private nonisolated static func makeProcess(executablePath: String, arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin"
        process.environment = env
        return process
    }

    private nonisolated static func installTerminationHandler(
        on process: Process,
        state: StreamingProcessState,
        completionGroup: DispatchGroup
    ) {
        completionGroup.enter()
        process.terminationHandler = { terminatedProcess in
            state.recordTerminationStatus(terminatedProcess.terminationStatus)
            completionGroup.leave()
        }
    }

    private nonisolated static func run(
        _ process: Process,
        pipes: StreamingPipes,
        continuation: AsyncThrowingStream<CLIStreamChunk, Error>.Continuation
    ) throws {
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            pipes.closeReadingAndWriting()
            continuation.finish(throwing: CLIError.notInstalled)
            throw CLIError.notInstalled
        }
    }

    private nonisolated static func startReaders(
        pipes: StreamingPipes,
        context: StreamingReaderContext,
        state: StreamingProcessState
    ) {
        Self.startReader(
            handle: pipes.stdout.fileHandleForReading,
            context: context,
            chunk: CLIStreamChunk.stdout,
            append: { state.appendStdout($0) }
        )
        Self.startReader(
            handle: pipes.stderr.fileHandleForReading,
            context: context,
            chunk: CLIStreamChunk.stderr,
            append: { state.appendStderr($0) }
        )
    }

    private nonisolated static func makeCompletionTask(
        state: StreamingProcessState,
        context: StreamingReaderContext
    ) -> Task<CLIStreamingResult, Error> {
        Task<CLIStreamingResult, Error> {
            try await withTaskCancellationHandler {
                try await context.waitForReadersAndTermination()
                do {
                    let result = try state.finish()
                    context.continuation.finish()
                    return result
                } catch {
                    context.continuation.finish(throwing: error)
                    throw error
                }
            } onCancel: {
                state.terminate()
            }
        }
    }

    private nonisolated static func startReader(
        handle: FileHandle,
        context: StreamingReaderContext,
        chunk: @escaping @Sendable (String) -> CLIStreamChunk,
        append: @escaping @Sendable (String) -> Void
    ) {
        context.completionGroup.enter()
        context.readerQueue.async {
            defer { context.completionGroup.leave() }
            while true {
                let data = handle.availableData
                guard data.isEmpty == false else { return }
                guard let text = String(data: data, encoding: .utf8) else { continue }
                append(text)
                context.continuation.yield(chunk(text))
            }
        }
    }
}

private nonisolated struct StreamingPipes {
    let stdout = Pipe()
    let stderr = Pipe()

    func attach(to process: Process) {
        process.standardOutput = stdout
        process.standardError = stderr
    }

    func closeReadingAndWriting() {
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
    }
}

private nonisolated final class StreamingReaderContext: @unchecked Sendable {
    let completionGroup = DispatchGroup()
    let readerQueue = DispatchQueue(label: "codes.petr.quick-access-for-pass.cli-stream-reader", attributes: .concurrent)
    let continuation: AsyncThrowingStream<CLIStreamChunk, Error>.Continuation

    init(continuation: AsyncThrowingStream<CLIStreamChunk, Error>.Continuation) {
        self.continuation = continuation
    }

    func waitForReadersAndTermination() async throws {
        try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void, Error>) in
            completionGroup.notify(queue: readerQueue) {
                resume.resume(returning: ())
            }
        }
    }
}

protocol CLIOutputRecording: Sendable {
    nonisolated func append(_ text: String)
    nonisolated func finalize() -> String
}

private nonisolated final class RawCLIOutputRecorder: CLIOutputRecording, @unchecked Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: "")

    func append(_ text: String) {
        storage.withLock { $0 += text }
    }

    func finalize() -> String {
        storage.withLock { $0 }
    }
}

private nonisolated final class RedactedCLIOutputRecorder: CLIOutputRecording, @unchecked Sendable {
    private struct Storage {
        var output = ""
        var pending = ""
        var isInsideLoginURL = false
    }

    private static let loginPrefix = "https://account.proton.me/desktop/login"
    private static let payloadPattern = #"#?payload=[^\s<>\"]+"#
    private static let redactionMarker = "[Proton login URL redacted]"

    private let redact: @Sendable (String) -> String
    private let storage = OSAllocatedUnfairLock(initialState: Storage())

    init(redact: @escaping @Sendable (String) -> String) {
        self.redact = redact
    }

    func append(_ text: String) {
        storage.withLock { storage in
            storage.pending += text
            Self.drain(&storage, redact: redact, final: false)
        }
    }

    func finalize() -> String {
        storage.withLock { storage in
            Self.drain(&storage, redact: redact, final: true)
            return storage.output
        }
    }

    private static func drain(
        _ storage: inout Storage,
        redact: @Sendable (String) -> String,
        final: Bool
    ) {
        while storage.pending.isEmpty == false {
            if storage.isInsideLoginURL {
                if let delimiter = storage.pending.firstIndex(where: isLoginURLDelimiter) {
                    let suffix = storage.pending[delimiter...]
                    storage.pending = String(suffix)
                    storage.isInsideLoginURL = false
                    continue
                }
                if final {
                    storage.pending.removeAll()
                }
                return
            }

            if let range = storage.pending.range(of: loginPrefix) {
                let safePrefix = String(storage.pending[..<range.lowerBound])
                storage.output += redactSafe(safePrefix, using: redact)
                storage.output += redactionMarker
                storage.pending = String(storage.pending[range.upperBound...])
                storage.isInsideLoginURL = true
                continue
            }

            let possibleSensitiveTail = possibleLoginPrefixSuffixLength(in: storage.pending)
            if final, possibleSensitiveTail == storage.pending.count, possibleSensitiveTail > 0 {
                storage.output += redactionMarker
                storage.pending.removeAll()
                return
            }

            let keepCount = final ? 0 : possibleSensitiveTail
            if keepCount == storage.pending.count { return }

            let splitIndex = storage.pending.index(storage.pending.endIndex, offsetBy: -keepCount)
            let safe = String(storage.pending[..<splitIndex])
            storage.output += redactSafe(safe, using: redact)
            storage.pending = String(storage.pending[splitIndex...])
        }
    }

    private static func redactSafe(_ text: String, using redact: @Sendable (String) -> String) -> String {
        redact(text).replacingOccurrences(
            of: payloadPattern,
            with: redactionMarker,
            options: .regularExpression
        )
    }

    private static func possibleLoginPrefixSuffixLength(in text: String) -> Int {
        let maxLength = min(text.count, loginPrefix.count - 1)
        guard maxLength > 0 else { return 0 }
        for length in stride(from: maxLength, through: 1, by: -1) {
            let suffix = String(text.suffix(length))
            if loginPrefix.hasPrefix(suffix) { return length }
        }
        return 0
    }

    private static func isLoginURLDelimiter(_ character: Character) -> Bool {
        character.isWhitespace || character == "<" || character == ">" || character == "\""
    }
}

extension CLIOutputCapturePolicy {
    nonisolated func makeRecorder() -> any CLIOutputRecording {
        switch self {
        case .raw:
            RawCLIOutputRecorder()
        case .redacted(let redact):
            RedactedCLIOutputRecorder(redact: redact)
        }
    }
}

private nonisolated final class StreamingProcessState: @unchecked Sendable {
    private struct Storage {
        var process: Process
        var stdoutRecorder: any CLIOutputRecording
        var stderrRecorder: any CLIOutputRecording
        var terminationStatus: Int32?
        var readerError: Error?
        var isFinished = false
    }

    private let storage: OSAllocatedUnfairLock<Storage>

    init(process: Process, capturePolicy: CLIOutputCapturePolicy) {
        storage = OSAllocatedUnfairLock(initialState: Storage(
            process: process,
            stdoutRecorder: capturePolicy.makeRecorder(),
            stderrRecorder: capturePolicy.makeRecorder()
        ))
    }

    func appendStdout(_ text: String) {
        storage.withLock { $0.stdoutRecorder.append(text) }
    }

    func appendStderr(_ text: String) {
        storage.withLock { $0.stderrRecorder.append(text) }
    }

    func recordTerminationStatus(_ status: Int32) {
        storage.withLock { $0.terminationStatus = status }
    }

    func recordReaderError(_ error: Error) {
        storage.withLock { storage in
            if storage.readerError == nil { storage.readerError = error }
        }
    }

    func finish() throws -> CLIStreamingResult {
        try storage.withLock { storage in
            storage.isFinished = true
            defer { storage.process.terminationHandler = nil }
            if let readerError = storage.readerError { throw readerError }
            return CLIStreamingResult(
                terminationStatus: storage.terminationStatus ?? storage.process.terminationStatus,
                stdout: storage.stdoutRecorder.finalize(),
                stderr: storage.stderrRecorder.finalize()
            )
        }
    }

    func terminate() {
        storage.withLock { storage in
            guard storage.isFinished == false, storage.process.isRunning else { return }
            storage.process.terminate()
        }
    }
}
