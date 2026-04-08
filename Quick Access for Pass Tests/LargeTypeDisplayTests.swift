import Testing
@testable import Quick_Access_for_Pass

@Suite("LargeTypeDisplay")
struct LargeTypeDisplayTests {
    @Test func acceptsSingleLineValueAt64Characters() throws {
        let value = String(repeating: "A", count: 64)
        let display = try LargeTypeDisplay(validating: value)
        #expect(display.tiles.count == 64)
        #expect(display.tiles[0].position == 1)
        #expect(display.tiles[63].position == 64)
    }

    @Test func rejectsMultilineValue() {
        #expect(throws: LargeTypeDisplay.ValidationError.self) {
            try LargeTypeDisplay(validating: "one\ntwo")
        }
    }

    @Test func rejectsOver64Characters() {
        #expect(throws: LargeTypeDisplay.ValidationError.self) {
            try LargeTypeDisplay(validating: String(repeating: "1", count: 65))
        }
    }

    @Test func classifiesLettersDigitsAndSymbols() throws {
        let display = try LargeTypeDisplay(validating: "A1@")
        #expect(display.tiles.map(\.characterClass) == [.letter, .digit, .symbol])
        #expect(display.tiles.map(\.parity) == [.odd, .even, .odd])
    }

    @Test func classifiesCombiningMarkGraphemesAsLetters() throws {
        let display = try LargeTypeDisplay(validating: "café")
        #expect(display.tiles.map(\.characterClass) == [.letter, .letter, .letter, .letter])
    }
}
