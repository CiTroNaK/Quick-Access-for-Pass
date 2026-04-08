import Foundation

extension SSHProxyCoordinator {
    func currentVaultFilter() -> [String] {
        let json = defaults.string(forKey: DefaultsKey.sshVaultFilter) ?? "[]"
        return (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
    }

    func waitForSocket(path: String, timeout: Int) async -> Bool {
        for _ in 0..<(timeout * 4) {
            if FileManager.default.fileExists(atPath: path) { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return FileManager.default.fileExists(atPath: path)
    }
}
