import Testing
@testable import Quick_Access_for_Pass

@Suite
struct RequesterHeaderContextTests {
    private func presentation(_ details: HerdrPaneDetails?) -> RequesterPresentation {
        .init(name: "Terminal", bundleURL: nil, symbolName: "terminal", hostID: nil, details: details)
    }

    @Test func omitsRepeatedSSHAndRunCommandsAfterWhitespaceNormalization() {
        let details = HerdrPaneDetails(workspaceLabel: nil, tabLabel: nil,
            paneTitle: "  git   fetch\n--all ", workingDirectory: nil)
        #expect(RequesterHeaderContext.rows(for: presentation(details), displayedCommand: "git fetch --all").isEmpty)
    }

    @Test(arguments: [nil, "", " \n\t "])
    func omitsMissingOrBlankPaneTitle(title: String?) {
        let details = HerdrPaneDetails(workspaceLabel: nil, tabLabel: nil, paneTitle: title, workingDirectory: nil)
        #expect(RequesterHeaderContext.rows(for: presentation(details), displayedCommand: "git fetch").isEmpty)
    }

    @Test(arguments: ["git fetch --all (workspace)", "Git fetch", "git fetch"])
    func retainsDistinctCaseSensitiveAndUnknownTitles(title: String) {
        let details = HerdrPaneDetails(workspaceLabel: nil, tabLabel: nil, paneTitle: title, workingDirectory: nil)
        let rows = RequesterHeaderContext.rows(for: presentation(details), displayedCommand: "git fetch --all")
        #expect(rows == [.init(kind: .paneTitle, value: title)])
    }

    @Test func returnsZeroTwoOrThreeVisibleRowsWithoutEmptyPlaceholders() {
        #expect(RequesterHeaderContext.rows(for: presentation(nil), displayedCommand: nil).isEmpty)
        let two = HerdrPaneDetails(workspaceLabel: nil, tabLabel: "Tab", paneTitle: nil, workingDirectory: "/tmp/work")
        #expect(RequesterHeaderContext.rows(for: presentation(two), displayedCommand: nil).count == 2)
        let three = HerdrPaneDetails(workspaceLabel: "Workspace", tabLabel: "Tab", paneTitle: "Shell", workingDirectory: "/tmp/work")
        #expect(RequesterHeaderContext.rows(for: presentation(three), displayedCommand: nil).count == 3)
    }

    @Test func joinsAvailableWorkspaceAndTabAndPreservesDirectory() {
        let workspaceOnly = HerdrPaneDetails(workspaceLabel: "  Work ", tabLabel: " \n", paneTitle: nil, workingDirectory: "~/work tree")
        #expect(RequesterHeaderContext.rows(for: presentation(workspaceOnly), displayedCommand: nil) == [
            .init(kind: .workspaceAndTab, value: "  Work "),
            .init(kind: .workingDirectory, value: "~/work tree")
        ])
        let both = HerdrPaneDetails(workspaceLabel: "Work", tabLabel: "Tab", paneTitle: nil, workingDirectory: nil)
        #expect(RequesterHeaderContext.rows(for: presentation(both), displayedCommand: nil) == [
            .init(kind: .workspaceAndTab, value: "Work / Tab")
        ])
        let tabOnly = HerdrPaneDetails(workspaceLabel: nil, tabLabel: "Tab", paneTitle: nil, workingDirectory: nil)
        #expect(RequesterHeaderContext.rows(for: presentation(tabOnly), displayedCommand: nil) == [
            .init(kind: .workspaceAndTab, value: "Tab")
        ])
    }
}
