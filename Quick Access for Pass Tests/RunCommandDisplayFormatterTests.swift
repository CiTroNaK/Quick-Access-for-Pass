import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite("Run command display formatter")
struct RunCommandDisplayFormatterTests {
    @Test("formats arguments without shell serialization", arguments: [
        (["gh", "--version"], "gh --version"),
        (["tool", "a b"], "tool \"a b\""),
        (["tool", ""], "tool \"\""),
        (["tool", "say \"hi\""], "tool \"say \\\"hi\\\"\""),
        (["tool", "a\\b"], "tool \"a\\\\b\""),
        (["tool", "a\tb"], "tool \"a\\tb\""),
        (["tool", "a\nb"], "tool \"a\\nb\""),
        (["tool", "a\\nb"], "tool \"a\\\\nb\""),
        (["tool", "café"], "tool \"café\"")
    ])
    func naturalPresentation(arguments: [String], expected: String) {
        #expect(RunCommandDisplayFormatter.text(for: arguments) == expected)
    }
}
