import AppKit
import SwiftUI
import Testing
@testable import Quick_Access_for_Pass

@Suite("AutoFill candidate picker presentation sizing")
@MainActor
struct AutoFillCandidatePickerPresentationTests {
    @Test("picker focus contract starts settled states at search and tabs between search and selected candidate")
    func pickerFocusContract() {
        let candidate = UUID()

        #expect(AutoFillCandidatePickerFocus.initialTarget(for: .siteResults([])) == .search)
        #expect(AutoFillCandidatePickerFocus.initialTarget(for: .searchResults([])) == .search)
        #expect(AutoFillCandidatePickerFocus.initialTarget(for: .empty) == .search)
        #expect(AutoFillCandidatePickerFocus.initialTarget(for: .unavailable) == .search)
        #expect(AutoFillCandidatePickerFocus.initialTarget(for: .waitingForRequest) == .cancel)
        #expect(AutoFillCandidatePickerFocus.initialTarget(for: .resolving) == .cancel)
        #expect(AutoFillCandidatePickerFocus.tabTarget(
            from: .search,
            selectedCandidateID: candidate,
            displayedCandidateIDs: [candidate]
        ) == .candidate(candidate))
        #expect(AutoFillCandidatePickerFocus.tabTarget(
            from: .search,
            selectedCandidateID: nil,
            displayedCandidateIDs: [candidate]
        ) == .cancel)
        #expect(AutoFillCandidatePickerFocus.shiftTabTarget(from: .candidate(candidate)) == .search)
    }

    @Test("tab from search falls back to cancel while loading retains a stale selection")
    func tabFromSearchRejectsStaleSelectionDuringLoading() {
        let staleCandidate = UUID()

        #expect(AutoFillCandidatePickerFocus.tabTarget(
            from: .search,
            selectedCandidateID: staleCandidate,
            displayedCandidateIDs: []
        ) == .cancel)
    }

    @Test("resolving cancel remains a native keyboard cancel action")
    func resolvingCancelUsesTheSharedKeyboardAction() {
        #expect(AutoFillResolvingPresentation.cancelAccessibilityLabel == "Cancel")
    }

    @Test("picker routes tab navigation through the displayed candidate set")
    func pickerTabNavigationUsesDisplayedCandidateSet() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Quick Access AutoFill/AutoFillCandidatePickerView.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("displayedCandidateIDs: Set(displayedCandidates.map(\\.descriptorID))"))
    }

    @Test("picker wires explicit focus targets and bypasses clear search in direct tab navigation")
    func pickerFocusSourceContract() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Quick Access AutoFill/AutoFillCandidatePickerView.swift"
            ),
            encoding: .utf8
        )

        for requiredSnippet in [
            "@FocusState private var focusTarget: AutoFillCandidatePickerFocusTarget?",
            "AutoFillPickerSearchField(",
            "focusTarget: $focusTarget",
            ".focused($focusTarget, equals: .candidate(candidate.descriptorID))",
            ".onKeyPress(.tab, phases: .down) { press in",
            "tabFromSearch()",
            "shiftTabFromCandidate()",
            "focusTarget = .candidate(identifier)",
            "AutoFillCandidatePickerFocus.initialTarget(for: newState)"
        ] {
            #expect(source.contains(requiredSnippet), "Missing picker focus behavior: \(requiredSnippet)")
        }
    }

    @Test("picker selection routes resolving presentation through the controller compact host")
    func resolvingContentUsesTheControllerCompactHostForBothPaths() throws {
        #expect(AutoFillResolvingPresentation.message == "Retrieving credential…")
        #expect(AutoFillResolvingPresentation.accessibilityLabel == "Retrieving credential")
        #expect(AutoFillResolvingPresentation.cancelAccessibilityLabel == "Cancel")

        let pickerSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Quick Access AutoFill/AutoFillCandidatePickerView.swift"
            ),
            encoding: .utf8
        )
        let providerSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Quick Access AutoFill/CredentialProviderViewController.swift"
            ),
            encoding: .utf8
        )

        #expect(pickerSource.contains("let onResolving: @MainActor () -> Void"))
        #expect(pickerSource.contains("if case .resolving = newState {\n                onResolving()\n            }"))
        #expect(pickerSource.contains("case .resolving:\n            EmptyView()"))
        #expect(providerSource.contains("onResolving: { [weak self] in\n                self?.showPickerResolvingView()\n            }"))
        #expect(providerSource.contains("private func showPickerResolvingView()"))
        #expect(providerSource.contains("private func installResolvingView()"))
        #expect(providerSource.contains("NSHostingView(rootView: AutoFillResolvingView"))
        #expect(providerSource.contains(".fixedSize())"))
        #expect(providerSource.contains("resolvingView.translatesAutoresizingMaskIntoConstraints = false"))
        #expect(providerSource.contains("resolvingView.layoutSubtreeIfNeeded()"))
        #expect(providerSource.contains("resolvingPresentationSize("))
        #expect(providerSource.contains("for: resolvingView.fittingSize"))
        #expect(providerSource.contains("self?.cancelInteractiveRequest()"))
        #expect(providerSource.contains("showPickerResolvingView() {\n        pickerModel?.cancel()") == false)
    }

    @Test("resolving presentation fits its content with a small edge inset")
    func resolvingPresentationSizeFitsContent() {
        let contentSize = CGSize(width: 236, height: 20)

        let size = AutoFillCandidatePickerPresentation.resolvingPresentationSize(
            for: contentSize
        )

        #expect(AutoFillCandidatePickerPresentation.resolvingEdgeInset == 12)
        #expect(size == CGSize(width: 260, height: 44))
        #expect(size.width > contentSize.width)
        #expect(size.height > contentSize.height)
    }

    @Test("rendered direct resolving host fits its shared row instead of the picker canvas")
    func renderedDirectResolvingHostIsCompact() {
        let viewController = NSViewController()
        viewController.view = NSView(frame: .zero)
        let hostingView = NSHostingView(rootView: AutoFillResolvingView(onCancel: {}).fixedSize())
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.layoutSubtreeIfNeeded()

        let fittingSize = hostingView.fittingSize
        let presentationSize = AutoFillCandidatePickerPresentation.resolvingPresentationSize(
            for: fittingSize
        )
        AutoFillCandidatePickerPresentation.applyContentSize(presentationSize, to: viewController)

        let inset = AutoFillCandidatePickerPresentation.resolvingEdgeInset * 2
        #expect(hostingView.translatesAutoresizingMaskIntoConstraints == false)
        #expect(fittingSize.width > 0)
        #expect(fittingSize.height > 0)
        #expect(presentationSize.width == fittingSize.width + inset)
        #expect(presentationSize.height == fittingSize.height + inset)
        #expect(presentationSize.width < AutoFillCandidatePickerPresentation.pickerContentSize.width)
        #expect(presentationSize.height < 180)
        #expect(fittingSize.height < 180 - inset)
        #expect(viewController.preferredContentSize == presentationSize)
        #expect(viewController.view.frame.size == .zero)
    }

    @Test("resolving presentation size remains positive for invalid fitting sizes")
    func resolvingPresentationSizeIsPositive() {
        let size = AutoFillCandidatePickerPresentation.resolvingPresentationSize(
            for: CGSize(width: 0, height: -10)
        )

        #expect(size.width > 0)
        #expect(size.height > 0)
    }

    @Test("picker uses the calm native list presentation contracts")
    func calmNativeListPresentationSource() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Quick Access AutoFill/AutoFillCandidatePickerView.swift"
            ),
            encoding: .utf8
        )

        for requiredSnippet in [
            "AutoFillPickerSearchField(",
            "Text(\"\\(count) credential",
            "Text(\"↑↓ Select · ↵ Fill\")",
            "VStack(alignment: .leading, spacing: AutoFillCandidatePickerPresentation.candidateRowSpacing)",
            "Rectangle().fill(isSelected ? Color.accentColor : Color.clear)",
            "Rectangle().fill(.separator)",
            "candidate.username.isEmpty ? \" \" : candidate.username",
            ".accessibilityAddTraits(isSelected ? .isSelected : [])"
        ] {
            #expect(source.contains(requiredSnippet), "Missing calm native list behavior: \(requiredSnippet)")
        }

        #expect(source.contains("Image(systemName: \"key.fill\")") == false)
        #expect(source.contains("RoundedRectangle(cornerRadius: 6).stroke") == false)
    }

    @Test("search uses the native AppKit control rather than a host-rendered SwiftUI text field")
    func searchPresentationUsesNativeAppKitControl() throws {
        let pickerSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Quick Access AutoFill/AutoFillCandidatePickerView.swift"
            ),
            encoding: .utf8
        )
        let fieldSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Quick Access AutoFill/AutoFillPickerSearchField.swift"
            ),
            encoding: .utf8
        )

        for requiredSnippet in [
            "AutoFillPickerSearchField(",
            "text: searchQuery",
            "focusTarget: $focusTarget",
            "onMoveSelectionUp: { _ = moveSelectionUp() }",
            "onMoveSelectionDown: { _ = moveSelectionDown() }",
            "onFill: { _ = fillSelectedCandidate() }",
            "onCancel: { _ = cancel() }",
            "onTab: { _ = tabFromSearch() }"
        ] {
            #expect(pickerSource.contains(requiredSnippet), "Missing native search integration: \(requiredSnippet)")
        }
        for requiredSnippet in [
            "struct AutoFillPickerSearchField: NSViewRepresentable",
            "NSSearchField",
            "placeholderString = \"Search credentials\"",
            "setAccessibilityLabel(\"Search credentials\")",
            "controlTextDidChange",
            "doCommandBy commandSelector: Selector",
            "#selector(NSResponder.moveUp(_:))",
            "#selector(NSResponder.moveDown(_:))",
            "#selector(NSResponder.insertNewline(_:))",
            "#selector(NSResponder.cancelOperation(_:))",
            "#selector(NSResponder.insertTab(_:))"
        ] {
            #expect(fieldSource.contains(requiredSnippet), "Missing native search-field behavior: \(requiredSnippet)")
        }
        #expect(pickerSource.contains("TextField(\"\", text: searchQuery)") == false)
        #expect(pickerSource.contains("Image(systemName: \"magnifyingglass\")") == false)
        #expect(pickerSource.contains("Image(systemName: \"xmark.circle.fill\")") == false)
        #expect(pickerSource.contains("RoundedRectangle(cornerRadius: 8, style: .continuous)") == false)
    }

    @Test("measured layout keeps a tall single row compact and reserves controls before capping the viewport")
    func measuredCandidateLayoutUsesActualGeometry() {
        let oneTallRow = AutoFillCandidatePickerPresentation.pickerPresentationSize(
            nonListContentHeight: 140,
            candidateRowHeights: [92]
        )
        let manyTallRows = AutoFillCandidatePickerPresentation.pickerPresentationSize(
            nonListContentHeight: 140,
            candidateRowHeights: [92, 92, 92, 92, 92]
        )

        #expect(oneTallRow == CGSize(width: 360, height: 232))
        #expect(manyTallRows == CGSize(width: 360, height: 416))
        #expect(
            AutoFillCandidatePickerPresentation.candidateListViewportHeight(
                nonListContentHeight: 180,
                candidateRowHeights: [48, 60, 72, 84, 120]
            ) == 180
        )
    }

    @Test("normal measured layouts use the largest complete prefix within the 420-point maximum")
    func normalMeasuredCandidateLayoutUsesCompletePrefixWithinMaximum() {
        let viewportHeight = AutoFillCandidatePickerPresentation.candidateListViewportHeight(
            nonListContentHeight: 250,
            candidateRowHeights: [80, 80, 80, 80, 80]
        )
        let size = AutoFillCandidatePickerPresentation.pickerPresentationSize(
            nonListContentHeight: 250,
            candidateRowHeights: [80, 80, 80, 80, 80]
        )

        #expect(viewportHeight == 160)
        #expect(size == CGSize(width: 360, height: 410))
        #expect(size.height <= AutoFillCandidatePickerPresentation.pickerContentSize.height)
    }

    @Test("zero row spacing keeps four 48-point rows in an exactly fitting viewport")
    func zeroRowSpacingKeepsFourWholeRowsWhenTheyExactlyFit() {
        let rowHeights: [CGFloat] = [48, 48, 48, 48, 48]

        let viewportAt192Points = AutoFillCandidatePickerPresentation.candidateListViewportHeight(
            nonListContentHeight: 228,
            candidateRowHeights: rowHeights
        )
        let viewportAt200Points = AutoFillCandidatePickerPresentation.candidateListViewportHeight(
            nonListContentHeight: 220,
            candidateRowHeights: rowHeights
        )

        #expect(AutoFillCandidatePickerPresentation.candidateRowSpacing == 0)
        #expect(viewportAt192Points == 192)
        #expect(viewportAt200Points == 192)
    }

    @Test("oversized first row expands only enough to show one whole row with controls")
    func oversizedFirstRowExpandsBeyondMaximumWithoutPartialFallback() {
        let viewportHeight = AutoFillCandidatePickerPresentation.candidateListViewportHeight(
            nonListContentHeight: 250,
            candidateRowHeights: [200, 80, 80]
        )
        let size = AutoFillCandidatePickerPresentation.pickerPresentationSize(
            nonListContentHeight: 250,
            candidateRowHeights: [200, 80, 80]
        )

        #expect(viewportHeight == 200)
        #expect(size == CGSize(width: 360, height: 450))
        #expect(size.height > AutoFillCandidatePickerPresentation.pickerContentSize.height)
        #expect(viewportHeight == 200)
    }

    @Test("rendered enlarged Dynamic Type picker reports overflow only for a whole first row")
    func renderedPickerReportsWholeRowOverflow() async throws {
        let candidate = AutoFillCandidate(
            descriptorID: UUID(),
            title: String(repeating: "A long credential title that wraps at the picker width ", count: 20),
            username: "long-name@example.com",
            kind: .password,
            matchTier: 0
        )
        let candidates = (0..<5).map { index in
            AutoFillCandidate(
                descriptorID: UUID(),
                title: "\(candidate.title) \(index)",
                username: candidate.username,
                kind: candidate.kind,
                matchTier: candidate.matchTier
            )
        }
        let model = AutoFillCandidatePickerModel(
            lister: RenderedPickerBroker(candidates: candidates),
            completion: RenderedPickerCompletion()
        )
        let service = try AutoFillServiceIdentifier(
            kind: .domain,
            identifier: "example.com",
            displayName: nil
        )
        await model.load(services: [service], kind: .password)

        let callback = PickerSizeCallback()
        var applyReportedSize: ((CGSize) -> Void)?
        let picker = AutoFillCandidatePickerView(
            model: model,
            onCancel: {},
            onContentSizeChange: { size in
                callback.sizes.append(size)
                applyReportedSize?(size)
            }
        )
        .environment(\.dynamicTypeSize, .accessibility5)
        let hostingView = NSHostingView(rootView: picker)
        hostingView.frame = NSRect(x: 0, y: 0, width: 360, height: 420)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.orderFrontRegardless()
        applyReportedSize = { [weak hostingView] size in
            hostingView?.frame.size = size
        }
        hostingView.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        for _ in 0..<10 {
            await Task.yield()
            hostingView.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
        }

        let reportedSize = try #require(callback.sizes.last)
        #expect(reportedSize.width == 360)
        #expect(reportedSize.height > AutoFillCandidatePickerPresentation.pickerContentSize.height)
        #expect(hostingView.fittingSize.height >= reportedSize.height)

        let searchField = try #require(
            hostingView.descendants(of: NSTextField.self).first { $0.isEditable }
        )
        let searchFrame = hostingView.convert(searchField.bounds, from: searchField)
        let scrollView = try #require(
            hostingView.descendants(of: NSScrollView.self).first {
                hostingView.convert($0.bounds, from: $0).minY >= searchFrame.maxY
            }
        )
        let clipView = scrollView.contentView
        let documentView = try #require(scrollView.documentView)
        let candidateRows = try #require(documentView.subviews.first?.subviews)
        #expect(candidateRows.count == candidates.count)
        let firstRow = candidateRows[0]
        let laterRow = candidateRows[4]
        let firstRowFrame = documentView.convert(firstRow.bounds, from: firstRow)
        let laterRowFrame = documentView.convert(laterRow.bounds, from: laterRow)
        let scrollFrame = hostingView.convert(scrollView.bounds, from: scrollView)
        let initialViewport = clipView.bounds

        #expect(hostingView.bounds.contains(searchFrame))
        #expect(scrollFrame.minY >= searchFrame.maxY)
        // This compares actual AppKit row and clip-view geometry, rather than
        // inferring a row height from the panel-size callback.
        #expect(initialViewport.height >= firstRowFrame.height)
        #expect(documentView.frame.height > initialViewport.height)
        #expect(initialViewport.intersects(laterRowFrame) == false)

        documentView.scrollToVisible(laterRowFrame)
        hostingView.layoutSubtreeIfNeeded()

        let scrolledViewport = clipView.bounds
        #expect(scrolledViewport.origin != initialViewport.origin)
        #expect(scrolledViewport.intersects(laterRowFrame))
    }

    @Test("applying picker presentation size updates only the container preference")
    func appliesPickerPresentationSizeWithoutMutatingTheRootViewFrame() {
        let viewController = NSViewController()
        let initialRootSize = CGSize(width: 360, height: 420)
        let rootView = NSView(frame: NSRect(origin: .zero, size: initialRootSize))
        viewController.view = rootView

        AutoFillCandidatePickerPresentation.applyContentSize(
            CGSize(width: 273, height: 56),
            to: viewController
        )

        #expect(viewController.preferredContentSize == CGSize(width: 273, height: 56))
        #expect(rootView.frame.size == initialRootSize)
    }

    @Test("credential-provider root remains inert until an Authentication Services callback mounts content")
    func credentialProviderDefersPresentationUntilARequestCallback() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Quick Access AutoFill/CredentialProviderViewController.swift"
            ),
            encoding: .utf8
        )
        let loadView = try #require(
            source.components(separatedBy: "    override func loadView() {").dropFirst().first?
                .components(separatedBy: "    override func prepareCredentialList(").first
        )

        #expect(loadView.contains("view = NSView(frame: .zero)"))
        #expect(loadView.contains("applyPreferredContentSize") == false)
        #expect(loadView.contains("applyContentSize") == false)
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private extension NSView {
    func descendants<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { subview in
            (subview as? T).map { [$0] } ?? []
                + subview.descendants(of: type)
        }
    }
}

private struct RenderedPickerBroker: AutoFillBrokerListing {
    let candidates: [AutoFillCandidate]

    func listCandidates(
        _: AutoFillCandidateQuery,
        deadline _: UInt64
    ) async throws -> [AutoFillCandidate] {
        candidates
    }
}

@MainActor
private final class RenderedPickerCompletion: AutoFillCandidatePickerCompleting {
    func provide(
        candidate _: AutoFillCandidate,
        appAssociationIntent _: AutoFillAppAssociationIntent?
    ) async {}
}

@MainActor
private final class PickerSizeCallback {
    var sizes: [CGSize] = []
}
