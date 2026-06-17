import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("Sync diagnostic file store")
struct SyncDiagnosticFileStoreTests {

    @Test("small skipped item lists do not create a file")
    func smallListDoesNotCreateFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let skipped = [makeSkipped(index: 0)]

        let url = try SyncDiagnosticFileStore.writeSkippedItems(skipped, baseDirectory: directory)

        #expect(url == nil)
    }

    @Test("large skipped item lists create sanitized file")
    func largeListCreatesSanitizedFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let skipped = (0...SyncDiagnosticFileStore.largeReportThreshold).map {
            makeSkipped(index: $0, reason: "failed for user@example.com at /Users/alice/item")
        }

        let url = try #require(try SyncDiagnosticFileStore.writeSkippedItems(skipped, baseDirectory: directory))
        let contents = try String(contentsOf: url, encoding: .utf8)

        #expect(url.path.contains("SyncDiagnostics"))
        #expect(contents.contains("index=0"))
        #expect(!contents.contains("user@example.com"))
        #expect(!contents.contains("/Users/alice"))
        #expect(contents.contains("[email redacted]"))
        #expect(contents.contains("~/item"))
    }

    private func makeSkipped(index: Int, reason: String = "expected String") -> SkippedSyncItem {
        SkippedSyncItem(
            vaultId: "vault",
            vaultName: "Personal",
            itemIndex: index,
            itemId: "item-\(index)",
            codingPath: "items.Index \(index).content",
            reason: reason
        )
    }
}
