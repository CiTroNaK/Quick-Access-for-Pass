import Testing
import Foundation
@testable import Quick_Access_for_Pass

struct CLIStreamingRunnerTests {
    @Test(.timeLimit(.minutes(1)))
    func capturesStdoutStderrAndExitStatus() async throws {
        let runner = LiveCLIStreamingRunner()
        let process = try runner.start(
            executablePath: "/bin/sh",
            arguments: ["-c", "printf 'out'; printf 'err' >&2; exit 7"],
            capturePolicy: .raw
        )

        let result = try await process.completion.value
        var chunks: [CLIStreamChunk] = []
        for try await chunk in process.chunks { chunks.append(chunk) }

        #expect(result.terminationStatus == 7)
        #expect(chunks.contains(.stdout("out")))
        #expect(chunks.contains(.stderr("err")))
        #expect(result.stdout == "out")
        #expect(result.stderr == "err")
    }

    @Test(.timeLimit(.minutes(1)))
    func redactedCapturePolicyDoesNotRetainLoginPayload() async throws {
        let runner = LiveCLIStreamingRunner()
        let loginURL = "https://account.proton.me/desktop/login?app=pass#payload=synthetic-test-payload"
        let process = try runner.start(
            executablePath: "/bin/sh",
            arguments: ["-c", "printf '\(loginURL)'"],
            capturePolicy: .redacted(PassCLILoginParser.redactedForCapture)
        )

        for try await _ in process.chunks {}
        let result = try await process.completion.value

        #expect(result.stdout.contains("https://account.proton.me/desktop/login") == false)
        #expect(result.stdout.contains("payload=") == false)
        #expect(result.stdout.contains("[Proton login URL redacted]") == true)
    }

    @Test
    func redactedRecorderDoesNotRetainSplitLoginPayload() {
        let recorder = CLIOutputCapturePolicy
            .redacted(PassCLILoginParser.redactedForCapture)
            .makeRecorder()

        recorder.append("before https://account.proton.me/desktop/login?app=pass#pay")
        recorder.append("load=synthetic-secret-payload after")
        let output = recorder.finalize()

        #expect(output.contains("https://account.proton.me/desktop/login") == false)
        #expect(output.contains("payload=") == false)
        #expect(output.contains("synthetic-secret-payload") == false)
        #expect(output.contains("[Proton login URL redacted]") == true)
        #expect(output.contains("before") == true)
    }

    @Test
    func redactedRecorderDoesNotRetainStandalonePayloadFragments() {
        let recorder = CLIOutputCapturePolicy
            .redacted(PassCLILoginParser.redactedForCapture)
            .makeRecorder()

        recorder.append("error payload=synthetic-secret-payload retry")
        let output = recorder.finalize()

        #expect(output.contains("payload=") == false)
        #expect(output.contains("synthetic-secret-payload") == false)
        #expect(output.contains("[Proton login URL redacted]") == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func capturesManySmallChunksWithoutDroppingFinalOutput() async throws {
        let runner = LiveCLIStreamingRunner()
        let command = "for i in $(seq 1 40); do printf \"out-$i\\n\"; printf \"err-$i\\n\" >&2; done"
        let process = try runner.start(
            executablePath: "/bin/sh",
            arguments: ["-c", command],
            capturePolicy: .raw
        )

        async let result = process.completion.value
        var chunks: [CLIStreamChunk] = []
        for try await chunk in process.chunks { chunks.append(chunk) }
        let completed = try await result

        #expect(completed.terminationStatus == 0)
        #expect(completed.stdout.contains("out-1"))
        #expect(completed.stdout.contains("out-40"))
        #expect(completed.stderr.contains("err-1"))
        #expect(completed.stderr.contains("err-40"))
        #expect(chunks.contains { if case .stdout(let text) = $0 { text.contains("out-40") } else { false } })
        #expect(chunks.contains { if case .stderr(let text) = $0 { text.contains("err-40") } else { false } })
    }

    @Test(.timeLimit(.minutes(1)))
    func terminateStopsLongRunningProcess() async throws {
        let runner = LiveCLIStreamingRunner()
        let process = try runner.start(executablePath: "/bin/sh", arguments: ["-c", "sleep 10"], capturePolicy: .raw)

        process.terminate()
        for try await _ in process.chunks {}
        let result = try await process.completion.value

        #expect(result.terminationStatus != 0)
    }
}
