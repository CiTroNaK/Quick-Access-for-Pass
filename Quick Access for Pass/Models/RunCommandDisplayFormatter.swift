import Foundation

nonisolated enum RunCommandDisplayFormatter {
    private static let safeBytes = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-".utf8)

    static func text(for arguments: [String]) -> String {
        arguments.map { argument in
            let bytes = Array(argument.utf8)
            if !bytes.isEmpty && bytes.allSatisfy(safeBytes.contains) {
                return argument
            }
            return argument.debugDescription
        }
        .joined(separator: " ")
    }
}
