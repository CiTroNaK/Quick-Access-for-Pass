import Foundation

nonisolated struct LargeTypeDisplay: Sendable, Equatable {
    nonisolated enum ValidationError: Error, Equatable, Sendable {
        case unsupportedRow
        case empty
        case multiline
        case tooLong(max: Int)
    }

    nonisolated enum CharacterClass: Sendable, Equatable {
        case letter
        case digit
        case symbol
    }

    nonisolated enum Parity: Sendable, Equatable {
        case odd
        case even
    }

    nonisolated struct Tile: Sendable, Equatable, Identifiable {
        let position: Int
        let character: String
        let characterClass: CharacterClass

        var id: Int { position }
        var parity: Parity { position.isMultiple(of: 2) ? .even : .odd }
    }

    nonisolated static let maxLength = 64

    let value: String
    let tiles: [Tile]

    nonisolated init(validating rawValue: String) throws {
        guard !rawValue.isEmpty else {
            throw ValidationError.empty
        }
        guard !rawValue.contains(where: { $0.isNewline }) else {
            throw ValidationError.multiline
        }
        guard rawValue.count <= Self.maxLength else {
            throw ValidationError.tooLong(max: Self.maxLength)
        }

        value = rawValue
        tiles = rawValue.enumerated().map { index, character in
            Tile(
                position: index + 1,
                character: String(character),
                characterClass: Self.classify(character)
            )
        }
    }

    nonisolated static func classify(_ character: Character) -> CharacterClass {
        if character.isLetter {
            return .letter
        }
        if character.isNumber {
            return .digit
        }
        return .symbol
    }
}
