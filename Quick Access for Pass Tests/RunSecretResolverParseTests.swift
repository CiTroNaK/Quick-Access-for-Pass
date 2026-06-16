import Foundation
import Testing
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

        let result = try await RunSecretResolver.resolve(
            mappings: mappings,
            cliPath: fakeCLI.path
        )

        #expect(result == ["TOKEN": "real-secret"])
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

        let outcome = ResolverOutcome()
        let task = Task {
            do {
                _ = try await RunSecretResolver.resolve(
                    mappings: mappings,
                    cliPath: fakeCLI.path
                )
                await outcome.recordSuccess()
            } catch {
                await outcome.record(error: error)
            }
        }

        for _ in 0..<30 {
            if await outcome.isFinished { break }
            try await Task.sleep(for: .milliseconds(100))
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
            Issue.record("Resolver did not finish after pass-cli exited before opening output")
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
