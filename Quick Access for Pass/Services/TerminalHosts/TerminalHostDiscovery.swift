import Foundation

nonisolated struct TerminalHostDiscovery {
    private let candidates: () -> [URL]
    private let fileManager: FileManager

    init(fileManager: FileManager = .default, candidates: (() -> [URL])? = nil) {
        self.fileManager = fileManager
        self.candidates = candidates ?? {
            let commonCandidates = ["/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"]
                .map(URL.init(fileURLWithPath:)) + [fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/herdr")]
            let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":")
                .filter { $0.hasPrefix("/") }
                .map { URL(fileURLWithPath: String($0)).appendingPathComponent("herdr") }
            return pathCandidates + commonCandidates
        }
    }

    func discoverHerdr() -> URL? {
        candidates().first { isExecutableRegularFile($0) }?.standardizedFileURL
    }

    func isExecutableRegularFile(_ url: URL) -> Bool {
        guard url.isFileURL,
              let attributes = try? fileManager.attributesOfItem(atPath: canonicalPath(for: url)),
              attributes[.type] as? FileAttributeType == .typeRegular else { return false }
        return fileManager.isExecutableFile(atPath: url.path)
    }

    func canonicalPath(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
