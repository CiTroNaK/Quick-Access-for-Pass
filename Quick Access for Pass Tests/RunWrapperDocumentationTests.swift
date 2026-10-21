import Foundation
import Testing

@Suite("Run wrapper documentation")
struct RunWrapperDocumentationTests {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    private let helperPlaceholder = "/Applications/Quick Access for Pass.app/Contents/Helpers/qa-run"

    @Test("Heroku wrapper uses the documented portable helper pattern")
    func herokuWrapperRunsWithoutRecursion() throws {
        try exerciseWrapper(label: "~/.local/bin/heroku", profile: "heroku-cli", command: "heroku")
    }

    @Test("GitHub CLI wrapper uses the documented portable helper pattern")
    func githubWrapperRunsWithoutRecursion() throws {
        try exerciseWrapper(label: "~/.local/bin/gh", profile: "github-cli", command: "gh")
    }

    @Test("Missing real command fails instead of resolving the shim recursively")
    func missingCommandFailsAfterShimExclusion() throws {
        try exerciseWrapper(
            label: "~/.local/bin/gh",
            profile: "github-cli",
            command: "gh",
            commandAvailable: false
        )
    }

    @Test("Equivalent shim directory spellings resolve the fake CLI without recursion",
          arguments: ["heroku", "gh"], [ShimPathSpelling.trailingSlash, .relative, .symlink])
    func equivalentShimDirectoriesAreExcluded(command: String, spelling: ShimPathSpelling) throws {
        try exerciseWrapper(
            label: "~/.local/bin/\(command)",
            profile: command == "gh" ? "github-cli" : "heroku-cli",
            command: command,
            shimSpelling: spelling
        )
    }

    @Test("Equivalent shim directory spellings fail once when the fake CLI is missing",
          arguments: ["heroku", "gh"], [ShimPathSpelling.trailingSlash, .relative, .symlink])
    func missingCommandWithEquivalentShimFailsWithoutRecursion(command: String, spelling: ShimPathSpelling) throws {
        try exerciseWrapper(
            label: "~/.local/bin/\(command)",
            profile: command == "gh" ? "github-cli" : "heroku-cli",
            command: command,
            commandAvailable: false,
            shimSpelling: spelling
        )
    }

    @Test("Excluding the shim preserves retained PATH spellings, order and empty entries",
          arguments: ["heroku", "gh"])
    func retainedPathEntriesArePreserved(command: String) throws {
        try exerciseWrapper(
            label: "~/.local/bin/\(command)",
            profile: command == "gh" ? "github-cli" : "heroku-cli",
            command: command,
            shimSpelling: .trailingSlash,
            preserveEmptyEntries: true
        )
    }

    enum ShimPathSpelling: Sendable {
        case literal, trailingSlash, relative, symlink
    }

    private func exerciseWrapper(
        label: String,
        profile: String,
        command: String,
        commandAvailable: Bool = true,
        shimSpelling: ShimPathSpelling = .literal,
        preserveEmptyEntries: Bool = false
    ) throws {
        let wrapper = try extractWrapper(label: label)
        #expect(wrapper.contains("#!/bin/bash"))
        #expect(wrapper.contains("\"${BASH_SOURCE[0]}\""))
        #expect(wrapper.contains("--profile \(profile)"))
        #expect(wrapper.contains("\"$@\""))
        #expect(wrapper.contains("exec env PATH="))

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("wrapper fixture \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let shimDirectory = temporary.appendingPathComponent("shim directory", isDirectory: true)
        let realDirectory = temporary.appendingPathComponent("real commands", isDirectory: true)
        let utilityDirectory = temporary.appendingPathComponent("utilities", isDirectory: true)
        let helperDirectory = temporary.appendingPathComponent("helper path with spaces", isDirectory: true)
        for directory in [shimDirectory, realDirectory, utilityDirectory, helperDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let shimAlias = temporary.appendingPathComponent("shim symlink")
        try FileManager.default.createSymbolicLink(at: shimAlias, withDestinationURL: shimDirectory)
        let shimPathEntry: String = switch shimSpelling {
        case .literal: shimDirectory.path
        case .trailingSlash: shimDirectory.path + "/"
        case .relative: "./shim directory"
        case .symlink: shimAlias.path
        }
        let retainedEntries = preserveEmptyEntries
            ? ["", realDirectory.path, "missing directory", utilityDirectory.path, ""]
            : [realDirectory.path, utilityDirectory.path]
        let pathEntries = [shimPathEntry] + retainedEntries + [shimDirectory.path]

        let helper = helperDirectory.appendingPathComponent("qa-run fake")
        try writeExecutable(helper, contents: """
            #!/bin/bash
            set -eu
            [[ "${FIXTURE_HELPER_ALREADY_CALLED-}" != 1 ]] || exit 99
            export FIXTURE_HELPER_ALREADY_CALLED=1
            printf '%s\\0' "$@" > "$FIXTURE_HELPER_ARGS"
            printf '%s' "$PATH" > "$FIXTURE_HELPER_PATH"
            [ "$1" = "--profile" ] && [ "$3" = "--" ]
            shift 3
            command -v "$1" >/dev/null || exit 127
            exec "$@"
            """)

        let realCommand = realDirectory.appendingPathComponent(command)
        if commandAvailable {
            try writeExecutable(realCommand, contents: """
                #!/bin/bash
                printf '%s\\0' "$0" "$@" > "$FIXTURE_COMMAND_ARGS"
                """)
        }
        try writeExecutable(utilityDirectory.appendingPathComponent("env"), contents: """
            #!/bin/bash
            set -eu
            while [[ "$1" == *=* ]]; do
              export "$1"
              shift
            done
            exec "$@"
            """)
        try writeExecutable(utilityDirectory.appendingPathComponent("dirname"), contents: """
            #!/bin/bash
            if [[ "$1" == "--" ]]; then shift; fi
            case "$1" in
              */*) printf '%s\\n' "${1%/*}" ;;
              *) printf '.\\n' ;;
            esac
            """)

        let scriptURL = shimDirectory.appendingPathComponent(command)
        let installed = wrapper.replacingOccurrences(of: helperPlaceholder, with: helper.path)
        try writeExecutable(scriptURL, contents: installed)

        let helperArgs = temporary.appendingPathComponent("helper args")
        let helperPath = temporary.appendingPathComponent("helper PATH")
        let commandArgs = temporary.appendingPathComponent("command args")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "exec \"$@\"", "wrapper fixture", command, "arg with spaces", "quote'\"inside", "--literal=$HOME"]
        process.currentDirectoryURL = temporary
        process.environment = [
            "PATH": pathEntries.joined(separator: ":"),
            "HOME": temporary.path,
            "BASH_ENV": temporary.appendingPathComponent("missing bash env").path,
            "FIXTURE_HELPER_ARGS": helperArgs.path,
            "FIXTURE_HELPER_PATH": helperPath.path,
            "FIXTURE_COMMAND_ARGS": commandArgs.path
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + .seconds(3)) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + .seconds(1))
            Issue.record("Wrapper fixture exceeded its 3-second timeout")
            return
        }

        #expect(process.terminationStatus == (commandAvailable ? 0 : 127))
        let capturedHelperArgs = try readNullSeparated(helperArgs)
        #expect(capturedHelperArgs == ["--profile", profile, "--", command, "arg with spaces", "quote'\"inside", "--literal=$HOME"])
        let capturedPath = try String(contentsOf: helperPath, encoding: .utf8)
        #expect(capturedPath == retainedEntries.joined(separator: ":"))
        if commandAvailable {
            #expect(try readNullSeparated(commandArgs) == [realCommand.path, "arg with spaces", "quote'\"inside", "--literal=$HOME"])
        } else {
            #expect(FileManager.default.fileExists(atPath: commandArgs.path) == false)
        }
    }

    private func extractWrapper(label: String) throws -> String {
        let path = root.appendingPathComponent("docs/run-proxy.md")
        let document = try String(contentsOf: path, encoding: .utf8)
        let marker = "### Wrapper: \(label)\n\n```bash\n"
        let sections = document.components(separatedBy: marker)
        guard sections.count == 2,
              let body = sections[1].components(separatedBy: "\n```").first else {
            Issue.record("Missing complete Bash wrapper labelled \(label)")
            throw WrapperFixtureError.missingExample(label)
        }
        return body + "\n"
    }

    private func writeExecutable(_ url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func readNullSeparated(_ url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    private enum WrapperFixtureError: Error {
        case missingExample(String)
    }
}
