import Foundation

/// Metadata-only identity of the file a CLI path resolves to; never authorization by itself.
/// An in-place upgrade (for example `brew upgrade`) changes inode, size or modification date.
nonisolated struct PassCLIExecutableFingerprint: Sendable, Equatable {
    let resolvedPath: String
    let fileSystemNumber: Int
    let fileNumber: Int
    let size: Int
    let modificationDate: Date

    /// Returns nil when the executable cannot be inspected; callers must then reprobe.
    static func live(path: String) -> PassCLIExecutableFingerprint? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved),
              let fileSystemNumber = (attributes[.systemNumber] as? NSNumber)?.intValue,
              let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.intValue,
              let size = (attributes[.size] as? NSNumber)?.intValue,
              let modificationDate = attributes[.modificationDate] as? Date else { return nil }
        return PassCLIExecutableFingerprint(resolvedPath: resolved, fileSystemNumber: fileSystemNumber,
                                            fileNumber: fileNumber, size: size,
                                            modificationDate: modificationDate)
    }
}
