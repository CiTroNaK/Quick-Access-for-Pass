import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("Bounded folder hierarchy")
struct FolderHierarchyTests {
    @Test("defensive bounds are explicit app limits")
    func limits() {
        #expect(FolderCatalogLimits.maximumFolders == 10_000)
        #expect(FolderCatalogLimits.maximumDepth == 64)
        #expect(FolderCatalogLimits.maximumAncestryRows == 640_000)
    }

    @Test("duplicate IDs, orphan parents, cycles, and self parents are rejected", arguments: [0, 1, 2, 3])
    func rejectsInvalidGraph(kind: Int) throws {
        let rows: [(String, String?, String)] = switch kind {
        case 0: [("a", nil, "A"), ("a", nil, "A again")]
        case 1: [("a", "missing", "A")]
        case 2: [("a", "b", "A"), ("b", "a", "B")]
        default: [("a", "a", "A")]
        }
        let data = try FolderCLIContractFixture.folders(rows)
        let stamp = try FolderCLIContractFixture.stamp()
        #expect(throws: (any Error).self) {
            try CLIFolderCatalogParser.parse(data, vault: FolderCLIContractFixture.vault, memberships: [:], stamp: stamp)
        }
    }

    @Test("same names do not merge identities")
    func sameNames() throws {
        let data = try FolderCLIContractFixture.folders([("a", nil, "same"), ("b", nil, "same")])
        let catalog = try CLIFolderCatalogParser.parse(data, vault: FolderCLIContractFixture.vault,
                                                      memberships: [:], stamp: FolderCLIContractFixture.stamp())
        #expect(Set(catalog.folders.map(\.id)) == ["a", "b"])
        #expect(catalog.ancestors.count == 2)
    }

    @Test("the maximum depth is valid and one level beyond fails", arguments: [64, 65])
    func depthBound(count: Int) throws {
        let rows: [(String, String?, String)] = (0..<count).map { index in
            ("f\(index)", index == 0 ? nil : "f\(index - 1)", "Folder \(index)")
        }
        let data = try FolderCLIContractFixture.folders(rows)
        let stamp = try FolderCLIContractFixture.stamp()
        if count == 64 {
            let catalog = try CLIFolderCatalogParser.parse(data, vault: FolderCLIContractFixture.vault,
                                                          memberships: [:], stamp: stamp)
            #expect(catalog.ancestors.count == 64 * 65 / 2)
        } else {
            #expect(throws: (any Error).self) {
                try CLIFolderCatalogParser.parse(data, vault: FolderCLIContractFixture.vault, memberships: [:], stamp: stamp)
            }
        }
    }

    @Test("folder count is checked before closure construction", arguments: [10_000, 10_001])
    func countBound(count: Int) throws {
        let rows: [(String, String?, String)] = (0..<count).map { ("f\($0)", nil, "Folder") }
        let data = try FolderCLIContractFixture.folders(rows)
        let stamp = try FolderCLIContractFixture.stamp()
        if count == 10_000 {
            let catalog = try CLIFolderCatalogParser.parse(data, vault: FolderCLIContractFixture.vault,
                                                          memberships: [:], stamp: stamp)
            #expect(catalog.ancestors.count == count)
        } else {
            #expect(throws: (any Error).self) {
                try CLIFolderCatalogParser.parse(data, vault: FolderCLIContractFixture.vault, memberships: [:], stamp: stamp)
            }
        }
    }
}
