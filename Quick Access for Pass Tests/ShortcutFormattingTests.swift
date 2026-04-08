import Testing
import AppKit
@testable import Quick_Access_for_Pass

@Suite("ShortcutFormatting Tests")
@MainActor
struct ShortcutFormattingTests {

    // MARK: - Key Code Mapping

    @Test func commonLetterKeys() {
        #expect(ShortcutFormatting.keyCodeToString[0] == "A")
        #expect(ShortcutFormatting.keyCodeToString[1] == "S")
        #expect(ShortcutFormatting.keyCodeToString[8] == "C")
        #expect(ShortcutFormatting.keyCodeToString[35] == "P")
    }

    @Test func numberKeys() {
        #expect(ShortcutFormatting.keyCodeToString[18] == "1")
        #expect(ShortcutFormatting.keyCodeToString[29] == "0")
    }

    @Test func functionKeys() {
        #expect(ShortcutFormatting.keyCodeToString[122] == "F1")
        #expect(ShortcutFormatting.keyCodeToString[111] == "F12")
    }

    @Test func spaceKey() {
        #expect(ShortcutFormatting.keyCodeToString[49] == "Space")
    }

    @Test func returnKey() {
        #expect(ShortcutFormatting.keyCodeToString[36] == "Return")
    }

    @Test func keypadEnterKey() {
        #expect(ShortcutFormatting.keyCodeToString[76] == "Enter")
    }

    @Test func unknownKeyCodeReturnsQuestionMark() {
        let label = ShortcutFormatting.label(keyCode: 999, modifiers: 0)
        #expect(label == "?")
    }

    // MARK: - Modifier Formatting

    @Test func commandModifier() {
        let result = ShortcutFormatting.modifiersString(Int(NSEvent.ModifierFlags.command.rawValue))
        #expect(result == "⌘")
    }

    @Test func shiftModifier() {
        let result = ShortcutFormatting.modifiersString(Int(NSEvent.ModifierFlags.shift.rawValue))
        #expect(result == "⇧")
    }

    @Test func optionModifier() {
        let result = ShortcutFormatting.modifiersString(Int(NSEvent.ModifierFlags.option.rawValue))
        #expect(result == "⌥")
    }

    @Test func controlModifier() {
        let result = ShortcutFormatting.modifiersString(Int(NSEvent.ModifierFlags.control.rawValue))
        #expect(result == "⌃")
    }

    @Test func combinedModifiersInOrder() {
        // Control + Option + Shift + Command should produce ⌃⌥⇧⌘
        let mods: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        let result = ShortcutFormatting.modifiersString(Int(mods.rawValue))
        #expect(result == "⌃⌥⇧⌘")
    }

    @Test func noModifiers() {
        let result = ShortcutFormatting.modifiersString(0)
        #expect(result == "")
    }

    // MARK: - Full Label

    @Test func labelWithCommandC() {
        // keyCode 8 = C, Command modifier
        let label = ShortcutFormatting.label(keyCode: 8, modifiers: Int(NSEvent.ModifierFlags.command.rawValue))
        #expect(label == "⌘C")
    }

    @Test func labelWithShiftCommandSpace() {
        // keyCode 49 = Space, Shift+Command
        let mods: NSEvent.ModifierFlags = [.shift, .command]
        let label = ShortcutFormatting.label(keyCode: 49, modifiers: Int(mods.rawValue))
        #expect(label == "⇧⌘Space")
    }

    @Test func labelWithShiftReturn() {
        let label = ShortcutFormatting.label(keyCode: 36, modifiers: Int(NSEvent.ModifierFlags.shift.rawValue))
        #expect(label == "⇧Return")
    }

    @Test func labelWithShiftKeypadEnter() {
        let label = ShortcutFormatting.label(keyCode: 76, modifiers: Int(NSEvent.ModifierFlags.shift.rawValue))
        #expect(label == "⇧Enter")
    }
}
