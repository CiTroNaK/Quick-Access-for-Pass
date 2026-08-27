import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("Pass CLI bundle metadata")
struct PassCLIBundleMetadataTests {
    @Test
    func releaseWorkflowVerifiesLatestVersionedResources() throws {
        let workflow = try String(
            contentsOf: repositoryRoot.appendingPathComponent(".github/workflows/release.yml"),
            encoding: .utf8
        )

        #expect(!workflow.contains("Contents/Helpers/pass-cli-arm64"))
        #expect(!workflow.contains("Contents/Helpers/pass-cli-x86_64"))
        #expect(workflow.contains("Contents/Resources/ProtonPassCLI"))
        #expect(workflow.contains("LATEST_VERSION=\"$(find \"$CLI_RESOURCES_DIR\" -mindepth 1 -maxdepth 1 -type d -exec basename {} \\; | sort -V | tail -n 1)\""))
        #expect(workflow.contains("\"$CLI_RESOURCES_DIR/$LATEST_VERSION/pass-cli-arm64\" --version"))
        #expect(workflow.contains("\"$CLI_RESOURCES_DIR/$LATEST_VERSION/pass-cli-x86_64\" --version"))
    }

    @Test
    func productionManifestPinsPassCLI233Assets() throws {
        let manifestData = try Data(contentsOf: repositoryRoot
            .appendingPathComponent("Quick Access for Pass/Resources/proton-pass-cli.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        let version = try #require(manifest.versions.first { $0.version == "2.3.3" })

        #expect(version.releaseURL == "https://github.com/protonpass/pass-cli/releases/tag/2.3.3")
        #expect(version.sourceURL == "https://github.com/protonpass/pass-cli/tree/2.3.3")
        #expect(
            version.assets["macos-aarch64"]?.url
                == "https://github.com/protonpass/pass-cli/releases/download/2.3.3/pass-cli-macos-aarch64"
        )
        #expect(
            version.assets["macos-aarch64"]?.sha256
                == "3281587ac9c50ae2f1604ba75e9d1d39b6debb221b65a6cc56f64d626ede3dbc"
        )
        #expect(
            version.assets["macos-x86_64"]?.url
                == "https://github.com/protonpass/pass-cli/releases/download/2.3.3/pass-cli-macos-x86_64"
        )
        #expect(
            version.assets["macos-x86_64"]?.sha256
                == "275f6159f63d152ecdd9d4e2969ef515291619005e0d30ab762daee26081621c"
        )
    }

    @Test
    func licenseNoticeCoversEveryBundledVersionAndAsset() throws {
        let manifestData = try Data(contentsOf: repositoryRoot
            .appendingPathComponent("Quick Access for Pass/Resources/proton-pass-cli.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        let noticesData = try Data(contentsOf: repositoryRoot
            .appendingPathComponent("Quick Access for Pass/Resources/licenses.json"))
        let notices = try JSONDecoder().decode([LicenseNotice].self, from: noticesData)
        let notice = try #require(notices.first { $0.title == "Proton Pass CLI" })

        for version in manifest.versions {
            #expect(notice.text.contains("Version: \(version.version)"))
            #expect(notice.text.contains(version.releaseURL))
            #expect(notice.text.contains(version.sourceURL))
            for asset in version.assets.values {
                #expect(notice.text.contains(asset.url))
                #expect(notice.text.contains(asset.sha256))
            }
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private struct Manifest: Decodable {
    let versions: [ManifestVersion]
}

private struct ManifestVersion: Decodable {
    let version: String
    let releaseURL: String
    let sourceURL: String
    let assets: [String: ManifestAsset]
}

private struct ManifestAsset: Decodable {
    let url: String
    let sha256: String
}

private struct LicenseNotice: Decodable {
    let title: String
    let url: String
    let text: String
}
