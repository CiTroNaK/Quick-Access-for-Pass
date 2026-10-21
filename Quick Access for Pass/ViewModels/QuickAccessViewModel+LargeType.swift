import Foundation

@MainActor
extension QuickAccessViewModel {
    func showSelectedRowInLargeType() {
        onActivity()
        guard let item = detailItem else { return }
        reconcileDetailSelection(for: item)
        guard let row = selectedDetailRow(for: item) else { return }
        if case .keepOfflineIndividually = row { return }

        inFlightCopy?.cancel()
        inFlightCopy = nil
        copyGeneration += 1
        inFlightLargeType?.cancel()
        largeTypeGeneration += 1
        let generation = largeTypeGeneration
        let releaseToken = secretReleaseGuard.capture()

        inFlightLargeType = Task { [weak self] in
            guard let self else { return }
            defer { finishLargeTypeTaskIfCurrent(generation) }
            await runLargeTypeTask(for: row, item: item, generation: generation, releaseToken: releaseToken)
        }
    }

    private func runLargeTypeTask(
        for row: DetailRow,
        item: PassItem,
        generation: Int,
        releaseToken: UUID
    ) async {
        do {
            let resolved = try await resolvedLargeTypeValue(
                for: row, item: item, generation: generation, releaseToken: releaseToken
            )
            guard canReleaseLargeType(generation, token: releaseToken), let actions = largeTypePresentation else { return }
            let display = try resolved.map { try LargeTypeDisplay(validating: $0) }
            let prepared = try actions.prepare(display.value)
            defer { actions.discard(prepared) }
            try actions.activate(prepared)
            try display.release(validating: {
                try Task.checkCancellation()
                guard self.canReleaseLargeType(generation, token: releaseToken) else { throw CancellationError() }
            }, effect: { _ in try actions.present(prepared) })
            actions.complete(prepared)
        } catch is CancellationError {
            return
        } catch let error as OfflineSecretResolver.Error {
            publishLargeTypeError(error.localizedDescription, generation: generation)
        } catch let error as CLIError where error.isAuthError {
            publishLargeTypeError(cliService.cliSelection.loginRequiredMessage, generation: generation)
        } catch let error as LargeTypeDisplay.ValidationError {
            publishLargeTypeError(message(for: error), generation: generation)
        } catch {
            publishLargeTypeError(String(localized: "Failed to show Large Type"), generation: generation)
        }
    }

    private func resolvedLargeTypeValue(
        for row: DetailRow,
        item: PassItem,
        generation: Int,
        releaseToken: UUID
    ) async throws -> ResolvedSecret<String> {
        let currentShareId = shareId(for: item)
        switch row {
        case .field(let key, _, _):
            lastCommand = "\(cliService.cliPath) item view --output json pass://\(currentShareId)/\(item.id)"
            let cliItem = try await secretResolver.resolveItem(itemId: item.id, vaultId: item.vaultId, shareId: currentShareId)
            try Task.checkCancellation()
            guard canReleaseLargeType(generation, token: releaseToken) else { throw CancellationError() }
            return try cliItem.map { item in
                guard let value = FieldExtractor.value(for: key, in: item) else {
                    throw LargeTypeDisplay.ValidationError.unsupportedRow
                }
                return value
            }
        case .namedAction(let action, _, _):
            return try await resolvedLargeTypeValue(
                for: action, item: item, generation: generation, releaseToken: releaseToken
            )
        case .sectionHeader, .offlineAvailability, .keepOfflineIndividually:
            throw LargeTypeDisplay.ValidationError.unsupportedRow
        }
    }

    private func resolvedLargeTypeValue(
        for action: ItemAction,
        item: PassItem,
        generation: Int,
        releaseToken: UUID
    ) async throws -> ResolvedSecret<String> {
        let currentShareId = shareId(for: item)
        switch action {
        case .copyUsername:
            return ResolvedSecret(value: item.subtitle, offlineCapability: nil)
        case .copyPassword:
            lastCommand = "\(cliService.cliPath) item view --output json pass://\(currentShareId)/\(item.id)"
            let detail = try await secretResolver.resolveItem(itemId: item.id, vaultId: item.vaultId, shareId: currentShareId)
            try Task.checkCancellation()
            guard canReleaseLargeType(generation, token: releaseToken) else { throw CancellationError() }
            return try detail.map { item in
                guard case .login(let login) = item.content.content else {
                    throw LargeTypeDisplay.ValidationError.unsupportedRow
                }
                return login.password
            }
        case .copyTotp:
            lastCommand = "\(cliService.cliPath) item totp --output json pass://\(currentShareId)/\(item.id)"
            let code = try await secretResolver.resolveTOTP(itemId: item.id, vaultId: item.vaultId, shareId: currentShareId)
            try Task.checkCancellation()
            guard canReleaseLargeType(generation, token: releaseToken) else { throw CancellationError() }
            return code
        case .openURL, .copyPrimary:
            throw LargeTypeDisplay.ValidationError.unsupportedRow
        }
    }

    private func isCurrentLargeTypeGeneration(_ generation: Int) -> Bool {
        largeTypeGeneration == generation
    }

    private func canReleaseLargeType(_ generation: Int, token: UUID) -> Bool {
        !Task.isCancelled && isCurrentLargeTypeGeneration(generation) && secretReleaseGuard.isCurrent(token)
    }

    private func publishLargeTypeError(_ message: String, generation: Int) {
        guard isCurrentLargeTypeGeneration(generation) else { return }
        errorMessage = message
    }

    private func finishLargeTypeTaskIfCurrent(_ generation: Int) {
        guard isCurrentLargeTypeGeneration(generation) else { return }
        inFlightLargeType = nil
    }

    private func message(for error: LargeTypeDisplay.ValidationError) -> String {
        switch error {
        case .unsupportedRow, .empty:
            String(localized: "This row can't be shown in Large Type")
        case .multiline:
            String(localized: "Multi-line values can't be shown in Large Type")
        case .tooLong:
            String(localized: "Value is too long for Large Type")
        }
    }
}
