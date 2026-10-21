import Foundation
import Testing
import os
@testable import Quick_Access_for_Pass

private actor ResolverOutcome {
    private(set) var commandFailureMessage: String?
    private(set) var unexpectedSuccess = false
    private(set) var unexpectedError: String?

    var isFinished: Bool {
        commandFailureMessage != nil || unexpectedSuccess || unexpectedError != nil
    }

    func recordSuccess() {
        unexpectedSuccess = true
    }

    func record(error: Error) {
        if case CLIError.commandFailed(let message) = error {
            commandFailureMessage = message
        } else {
            unexpectedError = String(describing: error)
        }
    }
}

@Suite("RunSecretResolver.parseEnvOutput")
struct RunSecretResolverParseTests {

    @Test("resolve reads real secret from private helper output when pass-cli masks stdout")
    func resolveUsesPrivateOutputWhenPassCLIMasksStdout() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("qa-run-resolver-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fakeCLI = directory.appendingPathComponent("pass-cli")
        let script = """
        #!/bin/sh
        if [ "$1" = "run" ] && [ "$4" = "--" ] && [ "$5" != "/usr/bin/env" ]; then
          output="$6"
          if [ ! -p "$output" ]; then
            echo "expected FIFO output channel" >&2
            exit 42
          fi
          printf 'TOKEN=real-secret\\0' > "$output"
          exit 0
        fi
        echo 'TOKEN=<concealed by Proton Pass>'
        """
        try script.write(to: fakeCLI, atomically: true, encoding: .utf8)
        chmod(fakeCLI.path, 0o700)

        let mappings = [
            RunProfileEnvMapping(
                id: nil,
                profileId: 1,
                envVariable: "TOKEN",
                secretReference: "pass://Vault/Item/token"
            )
        ]

        let trace = RunResolverDiagnosticTrace()
        defer { trace.report(caseName: "privateOutput") }
        let result = try await RunSecretResolver.resolve(
            mappings: mappings,
            cliPath: fakeCLI.path,
            lifecycleTesting: trace.lifecycle()
        )

        #expect(result == ["TOKEN": "real-secret"])
        trace.expectJoinedCleanup()
    }

    @Test("resolve throws when pass-cli exits before opening helper output")
    func resolveThrowsWhenPassCLIExitsBeforeOpeningOutput() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("qa-run-resolver-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fakeCLI = directory.appendingPathComponent("pass-cli")
        let script = """
        #!/bin/sh
        echo "pass-cli failed before helper opened output" >&2
        exit 42
        """
        try script.write(to: fakeCLI, atomically: true, encoding: .utf8)
        chmod(fakeCLI.path, 0o700)

        let mappings = [
            RunProfileEnvMapping(
                id: nil,
                profileId: 1,
                envVariable: "TOKEN",
                secretReference: "pass://Vault/Item/token"
            )
        ]

        let trace = RunResolverDiagnosticTrace()
        defer { trace.report(caseName: "earlyCLIFailure") }
        let outcome = ResolverOutcome()
        let task = Task {
            do {
                _ = try await RunSecretResolver.resolve(
                    mappings: mappings,
                    cliPath: fakeCLI.path,
                    lifecycleTesting: trace.lifecycle()
                )
                await outcome.recordSuccess()
            } catch {
                await outcome.record(error: error)
            }
        }

        do {
            for _ in 0..<30 {
                if await outcome.isFinished { break }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            task.cancel()
            await task.value
            throw error
        }

        if await outcome.unexpectedSuccess {
            await task.value
            Issue.record("Expected pass-cli failure to throw")
        } else if let message = await outcome.commandFailureMessage {
            await task.value
            #expect(message.contains("pass-cli failed before helper opened output"))
        } else if let error = await outcome.unexpectedError {
            await task.value
            Issue.record("Wrong error thrown: \(error)")
        } else {
            task.cancel()
            await task.value
            Issue.record("Resolver did not finish after pass-cli exited before opening output")
        }
        trace.expectJoinedCleanup()
    }

    @Test("cancelling a live resolver joins its unopened FIFO reader", .timeLimit(.minutes(1)))
    func cancellationJoinsFIFOReaderBeforeResolverReturns() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("qa-run-resolver-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = directory.appendingPathComponent("started")
        let fakeCLI = directory.appendingPathComponent("pass-cli")
        let script = """
        #!/bin/sh
        printf ready > '\(started.path)'
        exec /bin/sleep 5
        """
        try script.write(to: fakeCLI, atomically: true, encoding: .utf8)
        chmod(fakeCLI.path, 0o700)
        let mappings = [RunProfileEnvMapping(
            id: nil, profileId: 1, envVariable: "TOKEN", secretReference: "pass://Vault/Item/token"
        )]
        let trace = RunResolverDiagnosticTrace()
        defer { trace.report(caseName: "cancellation") }
        let task = Task {
            try await RunSecretResolver.resolve(
                mappings: mappings, cliPath: fakeCLI.path, lifecycleTesting: trace.lifecycle()
            )
        }
        do {
            for _ in 0..<30 {
                if FileManager.default.fileExists(atPath: started.path), trace.contains(.readerEntered) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try #require(FileManager.default.fileExists(atPath: started.path))
            try #require(trace.contains(.readerEntered))
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            trace.expectJoinedCleanup()
        } catch {
            task.cancel()
            _ = await task.result
            throw error
        }
    }

    @Test("parses plain key=value lines, filtering to requested keys")
    func parsesPlainLinesFilteredToRequestedKeys() {
        let output = """
            FOO=one
            BAR=two
            BAZ=three
            """
        let result = RunSecretResolver.parseEnvOutput(output, keys: ["FOO", "BAZ"])
        #expect(result == ["FOO": "one", "BAZ": "three"])
    }

    @Test("values containing `=` are preserved whole")
    func valuesContainingEqualsArePreserved() {
        let output = "TOKEN=abc=def=ghi"
        let result = RunSecretResolver.parseEnvOutput(output, keys: ["TOKEN"])
        #expect(result == ["TOKEN": "abc=def=ghi"])
    }

    @Test("lines without `=` are skipped silently")
    func malformedLinesAreSkipped() {
        let output = """
            GOOD=value
            this is not an env line
            ALSO_GOOD=another
            """
        let result = RunSecretResolver.parseEnvOutput(
            output,
            keys: ["GOOD", "ALSO_GOOD"]
        )
        #expect(result == ["GOOD": "value", "ALSO_GOOD": "another"])
    }

    @Test("empty output returns empty dictionary")
    func emptyOutputReturnsEmpty() {
        let result = RunSecretResolver.parseEnvOutput("", keys: ["FOO"])
        #expect(result.isEmpty)
    }

    @Test("empty value is preserved as empty string")
    func emptyValueIsPreserved() {
        let output = "FLAG="
        let result = RunSecretResolver.parseEnvOutput(output, keys: ["FLAG"])
        #expect(result == ["FLAG": ""])
    }

    @Test("parses NUL-delimited output from private env export helper")
    func parsesNULDelimitedOutput() {
        let output = "TOKEN=abc=def\0EMPTY=\0IGNORED=value\0"
        let result = RunSecretResolver.parseEnvOutput(output, keys: ["TOKEN", "EMPTY"])
        #expect(result == ["TOKEN": "abc=def", "EMPTY": ""])
    }
}

/// Diagnostic records contain only bounded event names and monotonic timestamps.
private struct RunResolverDiagnosticTrace: Sendable {
    private let phases = OSAllocatedUnfairLock(
        initialState: [(RunSecretResolver.LifecycleTesting.Event, UInt64)]()
    )

    func lifecycle() -> RunSecretResolver.LifecycleTesting {
        RunSecretResolver.LifecycleTesting(marker: { event in
            phases.withLock { phases in
                guard phases.count < 32 else { return }
                phases.append((event, DispatchTime.now().uptimeNanoseconds))
            }
        })
    }

    func contains(_ event: RunSecretResolver.LifecycleTesting.Event) -> Bool {
        phases.withLock { $0.contains(where: { $0.0 == event }) }
    }

    func expectJoinedCleanup() {
        let events = phases.withLock { $0.map(\.0) }
        guard let writer = events.firstIndex(of: .keepAliveClosed),
              let reader = events.firstIndex(of: .readerFinished),
              let resolver = events.firstIndex(of: .resolverFinished)
        else {
            Issue.record("Resolver lifecycle was missing a cleanup boundary")
            return
        }
        // Closing the writer can wake the reader before the closing thread
        // records its marker; require both cleanup boundaries before return.
        #expect(writer < resolver)
        #expect(reader < resolver)
    }

    func report(caseName: String) {
        let trace = phases.withLock { phases in
            phases.map { "\($0.0)@\($0.1)" }.joined(separator: ",")
        }
        print("RunResolver lifecycle trace [\(caseName)]: \(trace)")
    }
}
