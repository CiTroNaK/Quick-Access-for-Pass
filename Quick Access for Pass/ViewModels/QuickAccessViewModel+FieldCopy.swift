import Foundation

@MainActor
extension QuickAccessViewModel {
    /// Fetches the item, extracts exactly one field by key, copies it through
    /// the concealed clipboard, and drops the decoded item. Called from
    /// `handleEnter()` when a `.field` row is selected.
    func copyField(_ key: FieldKey, from item: PassItem) {
        lastCommand = "\(cliService.cliPath) item view --output json pass://\(item.vaultId)/\(item.id)"
        inFlightLargeType?.cancel()
        inFlightLargeType = nil
        largeTypeGeneration += 1
        inFlightCopy?.cancel()
        isActionLoading = true
        copyGeneration += 1
        let generation = copyGeneration
        inFlightCopy = Task { [weak self] in
            guard let self else { return }
            defer { self.finishCopyTaskIfCurrent(generation) }
            await self.runCopyFieldTask(key, from: item, generation: generation)
        }
    }

    private func runCopyFieldTask(_ key: FieldKey, from item: PassItem, generation: Int) async {
        do {
            guard let value = try await currentFieldValue(for: key, from: item, generation: generation) else {
                return
            }
            guard isCurrentCopyGeneration(generation) else { return }
            clipboardManager.copy(value, label: copyLabel(for: key))
            guard isCurrentCopyGeneration(generation) else { return }
            try? searchService.recordUsage(itemId: item.id)
            guard isCurrentCopyGeneration(generation) else { return }
            onDismiss()
        } catch is CancellationError {
            return
        } catch let error as CLIError where error.isAuthError {
            publishCopyError(String(localized: "Please log in: pass-cli login"), generation: generation)
        } catch {
            publishCopyError(String(localized: "Failed to copy field"), generation: generation)
        }
    }

    private func currentFieldValue(for key: FieldKey, from item: PassItem, generation: Int) async throws -> String? {
        let cliItem = try await fetchItem(item.id, item.vaultId)
        try Task.checkCancellation()
        guard isCurrentCopyGeneration(generation) else { return nil }

        guard let value = FieldExtractor.value(for: key, in: cliItem) else {
            publishCopyError(String(localized: "Field no longer available — refresh"), generation: generation)
            return nil
        }

        try Task.checkCancellation()
        guard isCurrentCopyGeneration(generation) else { return nil }
        return value
    }

    private func isCurrentCopyGeneration(_ generation: Int) -> Bool {
        copyGeneration == generation
    }

    private func publishCopyError(_ message: String, generation: Int) {
        guard isCurrentCopyGeneration(generation) else { return }
        errorMessage = message
    }

    private func finishCopyTaskIfCurrent(_ generation: Int) {
        guard isCurrentCopyGeneration(generation) else { return }
        isActionLoading = false
        inFlightCopy = nil
    }

    fileprivate func copyLabel(for key: FieldKey) -> String {
        let label: String
        switch key {
        case .extra(_, let name, _):
            label = name
        default:
            label = key.localizedLabel
        }
        let format = String(localized: "%@ copied")
        return String(format: format, locale: .current, label)
    }

    #if DEBUG
    func debugCopyLabel(for key: FieldKey) -> String {
        copyLabel(for: key)
    }
    #endif
}
