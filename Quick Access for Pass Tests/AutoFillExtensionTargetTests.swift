import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("AutoFill extension target boundary")
struct AutoFillExtensionTargetTests {
    @Test("extension has IPC-only capabilities and no host secret sources")
    func extensionTargetExcludesHostSecretAccess() throws {
        let extensionEntitlements = try Entitlements(
            at: repositoryRoot.appendingPathComponent("Quick Access AutoFill/Quick Access AutoFill.entitlements")
        )

        #expect(extensionEntitlements.autoFillCredentialProvider)
        #expect(extensionEntitlements.appGroups == ["group.codes.petr.quick-access-for-pass"])
        #expect(extensionEntitlements.keychainGroups.isEmpty)
        #expect(try extensionSourcePaths() == allowedExtensionSources)
        #expect(try extensionTargetHasNoGRDBDependency())
    }

    @Test("source entitlement verifier requires Keychain Sharing only on the host")
    func sourceEntitlementVerifierEnforcesHostOnlyKeychainSharing() throws {
        let result = try runVerifier(
            "--check-source-entitlements",
            "Quick Access for Pass/Quick Access for Pass.entitlements",
            "Quick Access AutoFill/Quick Access AutoFill.entitlements"
        )

        #expect(result.status == 0, "\(result.output)")

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let hostEntitlements = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Quick Access for Pass/Quick Access for Pass.entitlements"),
            encoding: .utf8
        )

        let invalidAppGroupEntitlements = temporaryDirectory.appendingPathComponent("extra-app-group.entitlements")
        let hostWithExtraAppGroup = hostEntitlements.replacingOccurrences(
            of: "\t\t<string>group.codes.petr.quick-access-for-pass</string>",
            with: "\t\t<string>group.codes.petr.quick-access-for-pass</string>\n\t\t<string>group.example.additional</string>"
        )
        #expect(hostWithExtraAppGroup != hostEntitlements)
        try hostWithExtraAppGroup.write(to: invalidAppGroupEntitlements, atomically: true, encoding: .utf8)

        let extraAppGroupResult = try runVerifier(
            "--check-source-entitlements",
            invalidAppGroupEntitlements.path,
            "Quick Access AutoFill/Quick Access AutoFill.entitlements"
        )
        #expect(extraAppGroupResult.status != 0)

        let invalidKeychainEntitlements = temporaryDirectory.appendingPathComponent("extra-keychain-group.entitlements")
        let hostWithExtraKeychainGroup = hostEntitlements.replacingOccurrences(
            of: "\t\t<string>$(AppIdentifierPrefix)codes.petr.quick-access-for-pass</string>",
            with: "\t\t<string>$(AppIdentifierPrefix)codes.petr.quick-access-for-pass</string>\n\t\t<string>$(AppIdentifierPrefix)codes.petr.quick-access-for-pass.additional</string>"
        )
        #expect(hostWithExtraKeychainGroup != hostEntitlements)
        try hostWithExtraKeychainGroup.write(to: invalidKeychainEntitlements, atomically: true, encoding: .utf8)

        let extraKeychainGroupResult = try runVerifier(
            "--check-source-entitlements",
            invalidKeychainEntitlements.path,
            "Quick Access AutoFill/Quick Access AutoFill.entitlements"
        )
        #expect(extraKeychainGroupResult.status != 0)

        let invalidExtensionEntitlements = temporaryDirectory.appendingPathComponent("extension.entitlements")
        let extensionEntitlements = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Quick Access AutoFill/Quick Access AutoFill.entitlements"),
            encoding: .utf8
        )
        let extensionWithKeychainSharing = extensionEntitlements.replacingOccurrences(
            of: "</dict>",
            with: "\t<key>keychain-access-groups</key>\n\t<array>\n\t\t<string>$(AppIdentifierPrefix)codes.petr.quick-access-for-pass</string>\n\t</array>\n</dict>"
        )
        try extensionWithKeychainSharing.write(to: invalidExtensionEntitlements, atomically: true, encoding: .utf8)

        let invalidResult = try runVerifier(
            "--check-source-entitlements",
            "Quick Access for Pass/Quick Access for Pass.entitlements",
            invalidExtensionEntitlements.path
        )
        #expect(invalidResult.status != 0)
    }

    private func extensionSourcePaths() throws -> Set<String> {
        let project = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Quick Access for Pass.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let phaseStart = "\t\tAF2000110000000000000011 /* Sources */ = {"
        let phaseEnd = "\t\t};\n/* End PBXSourcesBuildPhase section */"
        let phaseComponents = project.components(separatedBy: phaseStart)
        let phase = try #require(phaseComponents.dropFirst().first)
        let sourcePhase = try #require(phase.components(separatedBy: phaseEnd).first)
        let expression = try NSRegularExpression(pattern: #"/\* (.+) in Sources \*/"#)
        let range = NSRange(sourcePhase.startIndex..., in: sourcePhase)
        let explicitSources: Set<String> = Set(expression.matches(in: sourcePhase, range: range).compactMap { match in
            guard let pathRange = Range(match.range(at: 1), in: sourcePhase) else { return nil }
            return String(sourcePhase[pathRange])
        })

        #expect(project.contains("AF2000060000000000000006 /* Quick Access AutoFill */"))
        let synchronizedRoot = repositoryRoot.appendingPathComponent("Quick Access AutoFill")
        let synchronizedSources = (FileManager.default.enumerator(
            at: synchronizedRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )?.allObjects ?? []).compactMap { entry -> String? in
            guard let file = entry as? URL, file.pathExtension == "swift" else { return nil }
            return file.path.replacingOccurrences(of: repositoryRoot.path + "/", with: "")
        }

        return explicitSources.union(synchronizedSources)
    }

    private func extensionTargetHasNoGRDBDependency() throws -> Bool {
        let project = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Quick Access for Pass.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let targetStart = "\t\tAF2000090000000000000009 /* Quick Access AutoFill */ = {"
        let frameworkStart = "\t\tAF2000070000000000000007 /* Frameworks */ = {"
        let target = try #require(
            project.components(separatedBy: targetStart).dropFirst().first?.components(separatedBy: "\t\t};").first
        )
        let framework = try #require(
            project.components(separatedBy: frameworkStart).dropFirst().first?.components(separatedBy: "\t\t};").first
        )

        return !target.contains("GRDB") && !framework.contains("GRDB")
    }

    private let allowedExtensionSources: Set<String> = [
        "Quick Access for Pass/Services/AutoFill/AutoFillConstants.swift",
        "Quick Access for Pass/Services/AutoFill/AutoFillProtocolTypes.swift",
        "Quick Access for Pass/Services/AutoFill/AutoFillBrokerRequest.swift",
        "Quick Access for Pass/Services/AutoFill/AutoFillBrokerResponse.swift",
        "Quick Access for Pass/Services/AutoFill/AutoFillWire.swift",
        "Quick Access for Pass/Services/AutoFill/AutoFillPeerVerifier.swift",
        "Quick Access for Pass/Services/AutoFill/AutoFillBrokerClient.swift",
        "Quick Access for Pass/Services/AutoFill/AutoFillBrokerClientConnection.swift",
        "Quick Access for Pass/Services/AutoFill/AutoFillWorkspaceHostOpener.swift",
        "Quick Access AutoFill/AutoFillCandidatePickerModel.swift",
        "Quick Access AutoFill/AutoFillCandidatePickerView.swift",
        "Quick Access AutoFill/AutoFillPickerSearchField.swift",
        "Quick Access AutoFill/AutoFillExtensionCoordinator.swift",
        "Quick Access AutoFill/CredentialProviderViewController.swift"
    ]

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func runVerifier(_ arguments: String...) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["scripts/verify-autofill-entitlements.sh"] + arguments
        process.currentDirectoryURL = repositoryRoot
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        return (
            process.terminationStatus,
            String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
}

private struct Entitlements {
    let autoFillCredentialProvider: Bool
    let appGroups: [String]
    let keychainGroups: [String]

    init(at url: URL) throws {
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        let dictionary = try #require(plist as? [String: Any])

        autoFillCredentialProvider = dictionary[
            "com.apple.developer.authentication-services.autofill-credential-provider"
        ] as? Bool ?? false
        appGroups = dictionary["com.apple.security.application-groups"] as? [String] ?? []
        keychainGroups = dictionary["keychain-access-groups"] as? [String] ?? []
    }
}
