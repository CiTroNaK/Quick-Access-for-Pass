import Foundation

extension RunAuthWindowController {
    nonisolated static func extractSubcommand(from command: [String]) -> String {
        extractIdentifierTokens(from: command).joined(separator: " ")
    }

    nonisolated static func isIdentifierToken(_ token: String) -> Bool {
        guard let first = token.first, first.isASCII, first.isLetter else {
            return false
        }
        return token.allSatisfy { char in
            char.isASCII && (char.isLetter || char.isNumber || char == "_" || char == "-")
        }
    }

    nonisolated static func extractIdentifierTokens(from command: [String]) -> [String] {
        var tokens: [String] = []
        for token in command {
            guard isIdentifierToken(token) else { break }
            tokens.append(token)
            if tokens.count == 3 { break }
        }
        return tokens
    }

    /// Offers exact argv identity first, followed by the existing explicit broader prefixes.
    nonisolated static func authorizationScopes(from command: [String]) -> [RunAuthorizationScope] {
        guard let exact = RunAuthorizationScope.exact(command: command) else { return [] }
        return [exact] + scopeOptions(from: command).map { RunAuthorizationScope.prefix($0) }
    }

    nonisolated static func scopeOptions(from command: [String]) -> [String] {
        let tokens = extractIdentifierTokens(from: command)
        // Bare-command edge case: user literally invoked a single-token command.
        if command.count == 1, tokens.count == 1 {
            return [tokens[0]]
        }
        // Refuse to offer a scope that would widen to a single-token binary name.
        guard tokens.count >= 2 else { return [] }
        // Emit prefixes narrow → wide, floored at 2 tokens.
        return stride(from: tokens.count, through: 2, by: -1).map {
            tokens.prefix($0).joined(separator: " ")
        }
    }
}
