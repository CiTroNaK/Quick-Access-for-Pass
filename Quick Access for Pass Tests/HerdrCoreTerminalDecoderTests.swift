import Foundation
import Testing
@testable import Quick_Access_for_Pass

@Suite struct HerdrCoreTerminalDecoderTests {
    private func response(_ overrides: [String: Any?] = [:], id: Int = 1) -> Data {
        var result: [String: Any] = [
            "address": "t5", "title": "Herdr core documentation", "pid": 71479, "state": "live", "cwd": "/x",
            "foreground": ["argv": ["claude"], "cwd": "/y", "name": "claude", "pid": 76601],
            "labels": ["where": "Quick Access for Pass / Tab Name", "herdr.tab": "tb1"], "unknown_field": ["x": 1],
        ]
        result["name"] = NSNull()
        for (key, value) in overrides { result[key] = value ?? NSNull() }
        guard let data = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
        else { preconditionFailure("Invalid synthetic JSON fixture") }
        return data
    }

    @Test func decodesLiveUnnamedTerminal() throws {
        #expect(try HerdrCoreTerminalDecoder.terminal(fromResponse: response())
            == .init(address: "t5", name: nil, title: "Herdr core documentation", pid: 71479, state: "live",
                     workspaceAndTab: "Quick Access for Pass / Tab Name"))
    }

    @Test func nameWinsOverTitle() throws {
        let terminal = try HerdrCoreTerminalDecoder.terminal(fromResponse: response(["name": "review"]))
        let details = HerdrCoreTerminalDecoder.details(terminal: terminal, workingDirectory: nil, homeDirectory: "/U")
        #expect(details == .init(workspaceLabel: "Quick Access for Pass / Tab Name", tabLabel: nil, paneTitle: "review",
                                 workingDirectory: nil))
    }

    @Test func coreDetailsProduceHerdrRows() throws {
        let terminal = try HerdrCoreTerminalDecoder.terminal(fromResponse: response())
        let details = HerdrCoreTerminalDecoder.details(terminal: terminal, workingDirectory: "/U/p", homeDirectory: "/U")
        let presentation = RequesterPresentation(name: "Herdr Core", bundleURL: nil, symbolName: "app", hostID: nil,
                                                 details: details)
        #expect(RequesterHeaderContext.rows(for: presentation, displayedCommand: nil) == [
            .init(kind: .workspaceAndTab, value: "Quick Access for Pass / Tab Name"),
            .init(kind: .paneTitle, value: "Herdr core documentation"),
            .init(kind: .workingDirectory, value: "~/p"),
        ])
        #expect(RequesterHeaderContext.rows(for: presentation, displayedCommand: "Herdr core documentation").map(\.kind)
            == [.workspaceAndTab, .workingDirectory])
    }

    @Test(arguments: ["missing", "null", "number", "labelsArray"])
    func unusableWhereLabelIsIgnored(_ scenario: String) throws {
        let labels: Any? = switch scenario {
        case "missing": ["herdr.tab": "tb1"]
        case "null": nil
        case "number": ["where": 5]
        default: ["where"]
        }
        let terminal = try HerdrCoreTerminalDecoder.terminal(fromResponse: response(["labels": labels]))
        #expect(terminal.workspaceAndTab == nil)
        #expect(terminal.title == "Herdr core documentation")
    }

    @Test func hostileWhereLabelIsSanitized() throws {
        let terminal = try HerdrCoreTerminalDecoder.terminal(
            fromResponse: response(["labels": ["where": "\u{1b}]0;x\u{07}Work / Tab\n"]]))
        let details = HerdrCoreTerminalDecoder.details(terminal: terminal, workingDirectory: nil, homeDirectory: "/U")
        #expect(details?.workspaceLabel == "Work / Tab")
    }

    @Test(arguments: ["error", "wrongID", "noAddress", "noPID", "stringPID", "notJSON"])
    func invalidResponsesThrow(_ scenario: String) {
        let data: Data = switch scenario {
        case "error": Data(#"{"error":{"code":-32000,"data":{"kind":"not_found"},"message":"no terminal"},"id":1,"jsonrpc":"2.0"}"#.utf8)
        case "wrongID": response(id: 2)
        case "noAddress": response(["address": nil])
        case "noPID": response(["pid": nil])
        case "stringPID": response(["pid": "71479"])
        default: Data("not json".utf8)
        }
        #expect(throws: (any Error).self) { try HerdrCoreTerminalDecoder.terminal(fromResponse: data) }
    }

    @Test func hostileTitleIsSanitized() throws {
        let title = "\u{1b}[31mBuild\u{1b}[0m\nnext" + String(repeating: "x", count: 10_000)
        let terminal = try HerdrCoreTerminalDecoder.terminal(fromResponse: response(["title": title]))
        let label = try #require(HerdrCoreTerminalDecoder.details(terminal: terminal, workingDirectory: nil,
                                                                 homeDirectory: "/U")?.paneTitle)
        #expect(!label.contains("\u{1b}"))
        #expect(!label.contains("\n"))
        #expect(label.count <= 256)
    }

    @Test func homeIsAbbreviated() throws {
        let terminal = try HerdrCoreTerminalDecoder.terminal(fromResponse: response())
        let details = HerdrCoreTerminalDecoder.details(terminal: terminal, workingDirectory: "/Users/u/Code/p",
                                                       homeDirectory: "/Users/u")
        #expect(details?.workingDirectory == "~/Code/p")
    }

    @Test func allEmptyIsNil() throws {
        let terminal = try HerdrCoreTerminalDecoder.terminal(fromResponse: response(["title": "  ", "labels": nil]))
        #expect(HerdrCoreTerminalDecoder.details(terminal: terminal, workingDirectory: nil, homeDirectory: "/U") == nil)
    }
}
