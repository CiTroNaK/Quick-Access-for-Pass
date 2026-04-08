import AppKit

/// Maps Carbon key codes to display strings. Shared between the shortcut recorder and
/// shortcut label display so they stay in sync.
enum ShortcutFormatting {
    static let keyCodeToString: [UInt16: String] = [
         0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
         8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
        38: "J", 40: "K", 45: "N", 46: "M",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        36: "Return", 49: "Space", 76: "Enter",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    static func modifiersString(_ rawValue: Int) -> String {
        let mods = NSEvent.ModifierFlags(rawValue: UInt(rawValue))
        // modifier string accumulator
        // swiftlint:disable:next identifier_name
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        return s
    }

    static func label(keyCode: Int, modifiers: Int) -> String {
        modifiersString(modifiers) + (keyCodeToString[UInt16(keyCode)] ?? "?")
    }
}
