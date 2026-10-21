import AppKit
import SwiftUI

@MainActor
enum AutoFillResolvingPresentation {
    static let message = "Retrieving credential…"
    static let accessibilityLabel = "Retrieving credential"
    static let cancelAccessibilityLabel = "Cancel"
}

@MainActor
struct AutoFillResolvingView: View {
    let onCancel: @MainActor () -> Void
    let focusTarget: FocusState<AutoFillCandidatePickerFocusTarget?>.Binding?

    init(
        onCancel: @escaping @MainActor () -> Void,
        focusTarget: FocusState<AutoFillCandidatePickerFocusTarget?>.Binding? = nil
    ) {
        self.onCancel = onCancel
        self.focusTarget = focusTarget
    }

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .accessibilityHidden(true)
            Text(AutoFillResolvingPresentation.message)
                .font(.body)
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(AutoFillResolvingPresentation.cancelAccessibilityLabel)
                .modifier(AutoFillResolvingCancelFocusModifier(focusTarget: focusTarget))
        }
        .accessibilityLabel(AutoFillResolvingPresentation.accessibilityLabel)
    }
}

@MainActor
enum AutoFillCandidatePickerFocusTarget: Hashable {
    case search
    case candidate(UUID)
    case cancel
}

@MainActor
private struct AutoFillResolvingCancelFocusModifier: ViewModifier {
    let focusTarget: FocusState<AutoFillCandidatePickerFocusTarget?>.Binding?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let focusTarget {
            content.focused(focusTarget, equals: .cancel)
        } else { content }
    }
}

@MainActor
enum AutoFillCandidatePickerFocus {
    static func initialTarget(
        for state: AutoFillCandidatePickerModel.State
    ) -> AutoFillCandidatePickerFocusTarget {
        switch state {
        case .waitingForRequest, .resolving:
            .cancel
        case .loading, .siteResults, .searchResults, .empty, .unavailable:
            .search
        }
    }

    static func tabTarget(
        from target: AutoFillCandidatePickerFocusTarget,
        selectedCandidateID: UUID?,
        displayedCandidateIDs: Set<UUID>
    ) -> AutoFillCandidatePickerFocusTarget {
        guard case .search = target else { return target }
        guard let selectedCandidateID,
              displayedCandidateIDs.contains(selectedCandidateID) else { return .cancel }
        return .candidate(selectedCandidateID)
    }

    static func shiftTabTarget(
        from target: AutoFillCandidatePickerFocusTarget
    ) -> AutoFillCandidatePickerFocusTarget {
        guard case .candidate = target else { return target }
        return .search
    }
}

@MainActor
enum AutoFillCandidatePickerPresentation {
    static let pickerContentSize = CGSize(width: 360, height: 420)
    static let maximumVisibleCandidateRows = 4
    /// Must match the candidate stack spacing so viewport sizing includes no stale gaps.
    static let candidateRowSpacing: CGFloat = 0
    static let contentSpacing: CGFloat = 12
    static let contentEdgeInset: CGFloat = 16
    static let resolvingEdgeInset: CGFloat = 12

    /// Uses intrinsic control and row measurements. Normal layouts show the largest
    /// complete prefix (at most four rows) within 420 points. If controls plus the
    /// first row cannot fit, the presentation expands only for that whole row.
    static func candidateListViewportHeight(
        nonListContentHeight: CGFloat,
        candidateRowHeights: [CGFloat]
    ) -> CGFloat {
        let rows = candidateRowHeights
            .filter { $0.isFinite && $0 > 0 }
            .prefix(maximumVisibleCandidateRows)
        guard let firstRowHeight = rows.first else { return 0 }

        let controlsHeight = max(0, nonListContentHeight)
        let availableHeight = pickerContentSize.height - controlsHeight
        guard firstRowHeight <= availableHeight else { return firstRowHeight }

        var visibleHeight: CGFloat = firstRowHeight
        for rowHeight in rows.dropFirst() {
            let nextHeight = visibleHeight + candidateRowSpacing + rowHeight
            guard nextHeight <= availableHeight else { break }
            visibleHeight = nextHeight
        }
        return visibleHeight
    }

    static func pickerPresentationSize(
        nonListContentHeight: CGFloat,
        candidateRowHeights: [CGFloat]
    ) -> CGSize {
        let viewportHeight = candidateListViewportHeight(
            nonListContentHeight: nonListContentHeight,
            candidateRowHeights: candidateRowHeights
        )
        return CGSize(
            width: pickerContentSize.width,
            height: nonListContentHeight + viewportHeight
        )
    }

    static func resolvingPresentationSize(for fittingContentSize: CGSize) -> CGSize {
        let contentWidth = fittingContentSize.width.isFinite && fittingContentSize.width > 0
            ? fittingContentSize.width
            : 1
        let contentHeight = fittingContentSize.height.isFinite && fittingContentSize.height > 0
            ? fittingContentSize.height
            : 1
        let inset = resolvingEdgeInset * 2
        return CGSize(width: contentWidth + inset, height: contentHeight + inset)
    }

    /// Requests the size needed by the controller's active callback-owned content.
    /// Authentication Services owns the actual presentation frame.
    static func applyContentSize(_ size: CGSize, to viewController: NSViewController) {
        viewController.preferredContentSize = size
    }

    static func showsExactSiteMatch(
        for candidate: AutoFillCandidate,
        in state: AutoFillCandidatePickerModel.State
    ) -> Bool {
        guard candidate.matchTier == 0, case .siteResults = state else { return false }
        return true
    }

    static func accessibilityLabel(
        for candidate: AutoFillCandidate,
        in state: AutoFillCandidatePickerModel.State
    ) -> String {
        let label = "\(candidate.title), \(candidate.username)"
        return showsExactSiteMatch(for: candidate, in: state)
            ? "\(label), Exact site match"
            : label
    }
}

private struct AutoFillPickerTopControlsHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct AutoFillPickerBottomControlsHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct AutoFillPickerCandidateRowHeightsPreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGFloat] = [:]

    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

@MainActor
struct AutoFillCandidatePickerView: View {
    @State private var model: AutoFillCandidatePickerModel
    @State private var rememberForApp = false
    @State private var hoveredCandidateID: UUID?
    @State private var measuredTopControlsHeight: CGFloat = 0
    @State private var measuredBottomControlsHeight: CGFloat = 0
    @State private var measuredCandidateRowHeights: [UUID: CGFloat] = [:]
    @FocusState private var focusTarget: AutoFillCandidatePickerFocusTarget?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let onCancel: @MainActor () -> Void
    private let onResolving: @MainActor () -> Void
    private let onContentSizeChange: @MainActor (CGSize) -> Void

    init(
        model: AutoFillCandidatePickerModel,
        onCancel: @escaping @MainActor () -> Void,
        onResolving: @escaping @MainActor () -> Void = {},
        onContentSizeChange: @escaping @MainActor (CGSize) -> Void
    ) {
        _model = State(initialValue: model)
        self.onCancel = onCancel
        self.onResolving = onResolving
        self.onContentSizeChange = onContentSizeChange
    }

    var body: some View {
        @Bindable var bindableModel = model

        VStack(alignment: .leading, spacing: AutoFillCandidatePickerPresentation.contentSpacing) {
            topControls(searchQuery: $bindableModel.searchQuery)
            content
            bottomControls
        }
        .padding(AutoFillCandidatePickerPresentation.contentEdgeInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onPreferenceChange(AutoFillPickerTopControlsHeightPreferenceKey.self) { height in
            guard height.isFinite, height > 0 else { return }
            measuredTopControlsHeight = height
            updateContentSize()
        }
        .onPreferenceChange(AutoFillPickerBottomControlsHeightPreferenceKey.self) { height in
            guard height.isFinite, height > 0 else { return }
            measuredBottomControlsHeight = height
            updateContentSize()
        }
        .onPreferenceChange(AutoFillPickerCandidateRowHeightsPreferenceKey.self) { heights in
            measuredCandidateRowHeights = heights
            updateContentSize()
        }
        .onAppear {
            focusTarget = AutoFillCandidatePickerFocus.initialTarget(for: model.state)
            updateContentSize()
        }
        .onChange(of: model.selectedCandidateID) { _, identifier in
            if case .candidate = focusTarget, let identifier {
                focusTarget = .candidate(identifier)
            }
            guard let candidate = displayedCandidates.first(where: { $0.descriptorID == identifier }) else { return }
            AccessibilityNotification.Announcement("Selected \(candidate.title), \(candidate.username)").post()
        }
        .onChange(of: model.state) { oldState, newState in
            measuredCandidateRowHeights = [:]
            if case .resolving = newState {
                onResolving()
            }
            focusTarget = AutoFillCandidatePickerFocus.initialTarget(for: newState)
            updateContentSize()
            guard oldState != .unavailable, newState == .unavailable else { return }
            AccessibilityNotification.Announcement("Unable to load credentials. Try searching or reopen the picker.").post()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .waitingForRequest:
            Label("Waiting for credential request", systemImage: "key")
                .font(.body)
                .accessibilityLabel("Waiting for credential request")
        case .loading:
            HStack(spacing: 8) {
                ProgressView().accessibilityHidden(true)
                Text("Loading credentials…").font(.body)
            }
            .accessibilityLabel("Loading credentials")
        case .siteResults(let candidates), .searchResults(let candidates):
            candidateList(candidates)
        case .empty:
            Text("No matching credentials. Search by title or username.")
                .font(.body)
        case .unavailable:
            Text("Unable to load credentials. Try searching or reopen the picker.")
                .font(.body)
                .accessibilityLabel("Unable to load credentials")
        case .resolving:
            EmptyView()
        }
    }

    private func candidateList(_ candidates: [AutoFillCandidate]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: AutoFillCandidatePickerPresentation.candidateRowSpacing) {
                    ForEach(candidates, id: \.descriptorID) { candidate in
                        candidateRow(candidate)
                            .id(candidate.descriptorID)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(
                height: candidateListViewportHeight,
                alignment: .top
            )
            .onChange(of: model.selectedCandidateID) { _, identifier in
                guard let identifier else { return }
                var transaction = Transaction()
                transaction.animation = reduceMotion ? nil : .easeInOut(duration: 0.15)
                withTransaction(transaction) {
                    proxy.scrollTo(identifier, anchor: .center)
                }
            }
        }
    }

    private func candidateRow(_ candidate: AutoFillCandidate) -> some View {
        let isSelected = model.selectedCandidateID == candidate.descriptorID
        let isHovered = hoveredCandidateID == candidate.descriptorID
        let showsExactSiteMatch = AutoFillCandidatePickerPresentation.showsExactSiteMatch(
            for: candidate,
            in: model.state
        )
        return Button {
            Task { @MainActor in
                await model.select(candidate, rememberForApp: rememberForApp)
            }
        } label: {
            HStack(spacing: 8) {
                Rectangle().fill(isSelected ? Color.accentColor : Color.clear)
                    .frame(width: 3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.title).font(.body)
                    HStack(spacing: 4) {
                        Text(candidate.username.isEmpty ? " " : candidate.username)
                        if showsExactSiteMatch {
                            Text("Exact site match")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.16) : (isHovered ? Color.secondary.opacity(0.08) : Color.clear))
            .overlay(alignment: .bottom) {
                Rectangle().fill(.separator)
                    .frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: AutoFillPickerCandidateRowHeightsPreferenceKey.self,
                    value: [candidate.descriptorID: proxy.size.height]
                )
            }
        }
        .onHover { hoveredCandidateID = $0 ? candidate.descriptorID : nil }
        .accessibilityLabel(
            AutoFillCandidatePickerPresentation.accessibilityLabel(
                for: candidate,
                in: model.state
            )
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .focused($focusTarget, equals: .candidate(candidate.descriptorID))
        .onKeyPress(.upArrow, action: moveSelectionUp)
        .onKeyPress(.downArrow, action: moveSelectionDown)
        .onKeyPress(.return, action: fillSelectedCandidate)
        .onKeyPress(.escape, action: cancel)
        .onKeyPress(.tab, phases: .down) { press in
            guard press.modifiers.contains(.shift) else { return .ignored }
            return shiftTabFromCandidate()
        }
    }

    private var displayedCandidates: [AutoFillCandidate] {
        switch model.state {
        case .siteResults(let candidates), .searchResults(let candidates): candidates
        default: []
        }
    }

    private var candidateListViewportHeight: CGFloat? {
        guard displayedCandidates.isEmpty == false else { return nil }
        let rowHeights = displayedCandidates.compactMap {
            measuredCandidateRowHeights[$0.descriptorID]
        }
        guard rowHeights.isEmpty == false, nonListContentHeight > 0 else { return nil }
        return AutoFillCandidatePickerPresentation.candidateListViewportHeight(
            nonListContentHeight: nonListContentHeight,
            candidateRowHeights: rowHeights
        )
    }

    /// Control geometry is measured outside the scroll viewport, avoiding a sizing
    /// feedback loop with the hosting view's constrained list height.
    private var nonListContentHeight: CGFloat {
        measuredTopControlsHeight
            + measuredBottomControlsHeight
            + (AutoFillCandidatePickerPresentation.contentSpacing * 2)
            + (AutoFillCandidatePickerPresentation.contentEdgeInset * 2)
    }

    private func updateContentSize() {
        let size: CGSize
        if displayedCandidates.isEmpty == false {
            let rowHeights = displayedCandidates.compactMap {
                measuredCandidateRowHeights[$0.descriptorID]
            }
            if rowHeights.isEmpty == false, nonListContentHeight > 0 {
                size = AutoFillCandidatePickerPresentation.pickerPresentationSize(
                    nonListContentHeight: nonListContentHeight,
                    candidateRowHeights: rowHeights
                )
            } else {
                return
            }
        } else {
            return
        }
        onContentSizeChange(size)
    }

    private func topControls(searchQuery: Binding<String>) -> some View {
        Group {
            if canSearch {
                VStack(alignment: .leading, spacing: 4) {
                    AutoFillPickerSearchField(
                        text: searchQuery,
                        focusTarget: $focusTarget,
                        onMoveSelectionUp: { _ = moveSelectionUp() },
                        onMoveSelectionDown: { _ = moveSelectionDown() },
                        onFill: { _ = fillSelectedCandidate() },
                        onCancel: { _ = cancel() },
                        onTab: { _ = tabFromSearch() }
                    )
                    .frame(maxWidth: .infinity)
                    .onChange(of: searchQuery.wrappedValue) { _, query in
                        model.updateSearchQuery(query)
                    }
                    if case let .siteResults(candidates) = model.state {
                        resultCountLabel(candidates.count)
                    } else if case let .searchResults(candidates) = model.state {
                        resultCountLabel(candidates.count)
                    }
                }
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: AutoFillPickerTopControlsHeightPreferenceKey.self,
                    value: proxy.size.height
                )
            }
        }
    }

    private var bottomControls: some View {
        VStack(alignment: .leading, spacing: AutoFillCandidatePickerPresentation.contentSpacing) {
            if model.canRememberForApp, hasCandidates {
                Toggle("Remember for this app", isOn: $rememberForApp)
            }

            if isResolving == false {
                HStack {
                    Text("↑↓ Select · ↵ Fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Use up and down arrows to select, then Return to fill")
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel("Cancel")
                        .focused($focusTarget, equals: .cancel)
                }
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: AutoFillPickerBottomControlsHeightPreferenceKey.self,
                    value: proxy.size.height
                )
            }
        }
    }

    private func resultCountLabel(_ count: Int) -> some View {
        Text("\(count) credential\(count == 1 ? "" : "s")")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityLabel("\(count) matching credential\(count == 1 ? "" : "s")")
    }

    private var canSearch: Bool {
        switch model.state {
        case .waitingForRequest, .resolving: false
        default: true
        }
    }

    private var isResolving: Bool {
        if case .resolving = model.state { return true }
        return false
    }

    private var hasCandidates: Bool {
        switch model.state {
        case .siteResults, .searchResults: true
        default: false
        }
    }
}

private extension AutoFillCandidatePickerView {
    func moveSelectionUp() -> KeyPress.Result {
        model.moveSelection(by: -1)
        return .handled
    }

    func moveSelectionDown() -> KeyPress.Result {
        model.moveSelection(by: 1)
        return .handled
    }

    func fillSelectedCandidate() -> KeyPress.Result {
        Task { @MainActor in
            await model.selectActiveCandidate(rememberForApp: rememberForApp)
        }
        return .handled
    }

    func tabFromSearch() -> KeyPress.Result {
        focusTarget = AutoFillCandidatePickerFocus.tabTarget(
            from: .search,
            selectedCandidateID: model.selectedCandidateID,
            displayedCandidateIDs: Set(displayedCandidates.map(\.descriptorID))
        )
        return .handled
    }

    func shiftTabFromCandidate() -> KeyPress.Result {
        guard case let .candidate(identifier) = focusTarget else { return .ignored }
        focusTarget = AutoFillCandidatePickerFocus.shiftTabTarget(from: .candidate(identifier))
        return .handled
    }

    func cancel() -> KeyPress.Result {
        onCancel()
        return .handled
    }
}
