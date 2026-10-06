import Foundation
import Testing

struct BundledPassCLISigningTests {
    @Test func preservesBuiltAppCertificateWithMultipleKeychainIdentities() throws {
        let result = try runInjection()
        #expect(result.status == 0, Comment(rawValue: result.output))
        // SHA-1 of the fixture leaf certificate, not the first Keychain identity.
        #expect(result.identities == Array(repeating: "DAF0EE361582189C9F8CA10655F229FB961288A4", count: 3))
    }

    @Test func explicitSigningIdentityOverridesBuiltAppCertificate() throws {
        let result = try runInjection(override: "Explicit Signing Identity")
        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(result.identities == Array(repeating: "Explicit Signing Identity", count: 3))
    }

    @Test func missingBuiltAppCertificateFailsBeforeSigning() throws {
        let result = try runInjection(hasCertificate: false)
        #expect(result.status != 0)
        #expect(result.identities.isEmpty)
        #expect(result.output.contains("signing certificate"))
    }

    private struct Result {
        let status: Int32
        let identities: [String]
        let output: String
    }

    /// Only external signing/Keychain commands are faked; the injection script,
    /// certificate hashing, file installation, and helper execution run normally.
    private func runInjection(override: String? = nil, hasCertificate: Bool = true) throws -> Result {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }

        let bin = directory.appendingPathComponent("bin")
        let app = directory.appendingPathComponent("Fixture App.app")
        let prepared = directory.appendingPathComponent("prepared/1.0")
        for folder in [bin, app, prepared] {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        func executable(_ url: URL, _ body: String) throws {
            try body.write(to: url, atomically: true, encoding: .utf8)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        for architecture in ["arm64", "x86_64"] {
            try executable(prepared.appendingPathComponent("pass-cli-\(architecture)"), "#!/bin/sh\necho fixture-cli\n")
        }
        try executable(bin.appendingPathComponent("file"), "#!/bin/sh\necho 'Mach-O arm64 x86_64'\n")
        try executable(bin.appendingPathComponent("security"), """
        #!/bin/sh
        echo '  1) FAE5AA28F14A54C08ECD32D92DEA9D65E7590525 "Developer ID Application: First Certificate"'
        echo '  2) DAF0EE361582189C9F8CA10655F229FB961288A4 "Developer ID Application: Built App Certificate"'
        """)
        try executable(bin.appendingPathComponent("codesign"), """
        #!/bin/bash
        set -eu
        if [[ "$1" == "--force" ]]; then
            while [[ $# -gt 0 ]]; do
                if [[ "$1" == "--sign" ]]; then
                    printf '%s\\n' "$2" >> "$SIGNING_LOG"
                    exit 0
                fi
                shift
            done
            exit 1
        fi
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --extract-certificates=*)
                    [[ "$HAS_CERTIFICATE" == "1" ]] || exit 1
                    prefix="${1#--extract-certificates=}"
                    printf 'built app leaf certificate\\n' > "${prefix}0"
                    exit 0
                    ;;
                --entitlements)
                    echo '<?xml version="1.0"?><plist version="1.0"><dict/></plist>'
                    exit 0
                    ;;
            esac
            shift
        done
        """)

        let log = directory.appendingPathComponent("signing.log")
        let output = directory.appendingPathComponent("output.log")
        manager.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let script = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/inject-bundled-pass-cli.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, app.path, prepared.deletingLastPathComponent().path]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "SIGN_IDENTITY")
        environment["PATH"] = "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin"
        environment["SIGNING_LOG"] = log.path
        environment["HAS_CERTIFICATE"] = hasCertificate ? "1" : "0"
        if let override { environment["SIGN_IDENTITY"] = override }
        process.environment = environment
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()
        let identities = manager.fileExists(atPath: log.path)
            ? try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
            : []
        return Result(
            status: process.terminationStatus,
            identities: identities,
            output: try String(contentsOf: output, encoding: .utf8)
        )
    }
}
