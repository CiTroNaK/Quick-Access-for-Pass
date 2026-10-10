import Foundation

@MainActor
extension QuickAccessViewModel {
    /// Fetches the item, extracts exactly one field by key, copies it through
    /// the concealed clipboard, and drops the decoded item. Called from
    /// `handleEnter()` when a `.field` row is selected.
    func copyField(_ key: FieldKey, from item: PassItem) {
        lastCommand = "\(cliService.cliPath) item view --output json pass://\(shareId(for: item))/\(item.id)"
        inFlightLargeType?.cancel()
        inFlightLargeType = nil
        largeTypeGeneration += 1
        inFlightCopy?.cancel()
        copyGeneration += 1
        let generation = copyGeneration
        let releaseToken = secretReleaseGuard.capture()
        inFlightCopy = Task { [weak self] in
            guard let self else { return }
            defer { self.finishCopyTaskIfCurrent(generation) }
            await self.runCopyFieldTask(key, from: item, generation: generation, releaseToken: releaseToken)
        }
    }

    private func runCopyFieldTask(
        _ key: FieldKey,
        from item: PassItem,
        generation: Int,
        releaseToken: UUID
    ) async {
        do {
            guard let value = try await currentFieldValue(
                for: key, from: item, generation: generation, releaseToken: releaseToken
            ) else {
                return
            }
            guard canReleaseCopy(generation, token: releaseToken) else { return }
            try releaseCopy(value, label: copyLabel(for: key), generation: generation, token: releaseToken)
            guard canReleaseCopy(generation, token: releaseToken) else { return }
            try? searchService.recordUsage(itemId: item.id)
            guard canReleaseCopy(generation, token: releaseToken) else { return }
            onDismiss()
        } catch is CancellationError {
            return
        } catch let error as OfflineSecretResolver.Error {
            publishCopyError(error.localizedDescription, generation: generation)
        } catch let error as CLIError where error.isAuthError {
            publishCopyError(cliService.cliSelection.loginRequiredMessage, generation: generation)
        } catch {
            publishCopyError(String(localized: "Failed to copy field"), generation: generation)
        }
    }

    private func currentFieldValue(
        for key: FieldKey,
        from item: PassItem,
        generation: Int,
        releaseToken: UUID
    ) async throws -> ResolvedSecret<String>? {
        let cliItem = try await secretResolver.resolveItem(
            itemId: item.id, vaultId: item.vaultId, shareId: shareId(for: item)
        )
        try Task.checkCancellation()
        guard canReleaseCopy(generation, token: releaseToken) else { return nil }

        let extracted = cliItem.map { FieldExtractor.value(for: key, in: $0) }
        guard let value = extracted.value else {
            publishCopyError(String(localized: "Field no longer available — refresh"), generation: generation)
            return nil
        }

        try Task.checkCancellation()
        guard canReleaseCopy(generation, token: releaseToken) else { return nil }
        return extracted.map { _ in value }
    }

    func releaseCopy(_ resolved: ResolvedSecret<String>, label: String, generation: Int, token: UUID) throws {
        try resolved.release(validating: {
            try Task.checkCancellation()
            guard self.canReleaseCopy(generation, token: token) else { throw CancellationError() }
        }, effect: { self.clipboardManager.writeConcealedValue($0) })
        clipboardManager.completeCopy(label: label)
    }

    func isCurrentCopyGeneration(_ generation: Int) -> Bool {
        copyGeneration == generation
    }

    func canReleaseCopy(_ generation: Int, token: UUID) -> Bool {
        !Task.isCancelled && isCurrentCopyGeneration(generation) && secretReleaseGuard.isCurrent(token)
    }

    func publishCopyError(_ message: String, generation: Int) {
        guard isCurrentCopyGeneration(generation) else { return }
        errorMessage = message
    }

    func finishCopyTaskIfCurrent(_ generation: Int) {
        guard isCurrentCopyGeneration(generation) else { return }
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
