import Foundation

@MainActor
extension QuickAccessViewModel {
    func showSelectedRowInLargeType() {
        onActivity()
        guard let item = detailItem else { return }
        let rows = rows(for: item)
        guard let row = rows[safe: selectedRowIndex], row.isSelectable else { return }

        inFlightCopy?.cancel()
        inFlightCopy = nil
        copyGeneration += 1
        inFlightLargeType?.cancel()
        isActionLoading = true
        largeTypeGeneration += 1
        let generation = largeTypeGeneration

        inFlightLargeType = Task { [weak self] in
            guard let self else { return }
            defer { finishLargeTypeTaskIfCurrent(generation) }
            await runLargeTypeTask(for: row, item: item, generation: generation)
        }
    }

    private func runLargeTypeTask(for row: DetailRow, item: PassItem, generation: Int) async {
        do {
            let rawValue = try await resolvedLargeTypeValue(for: row, item: item, generation: generation)
            guard isCurrentLargeTypeGeneration(generation) else { return }
            let display = try LargeTypeDisplay(validating: rawValue)
            guard isCurrentLargeTypeGeneration(generation) else { return }
            presentLargeType(display)
        } catch is CancellationError {
            return
        } catch let error as CLIError where error.isAuthError {
            publishLargeTypeError(String(localized: "Please log in: pass-cli login"), generation: generation)
        } catch let error as LargeTypeDisplay.ValidationError {
            publishLargeTypeError(message(for: error), generation: generation)
        } catch {
            publishLargeTypeError(String(localized: "Failed to show Large Type"), generation: generation)
        }
    }

    private func resolvedLargeTypeValue(for row: DetailRow, item: PassItem, generation: Int) async throws -> String {
        switch row {
        case .field(let key, _, _):
            lastCommand = "\(cliService.cliPath) item view --output json pass://\(item.vaultId)/\(item.id)"
            let cliItem = try await fetchItem(item.id, item.vaultId)
            try Task.checkCancellation()
            guard isCurrentLargeTypeGeneration(generation) else { throw CancellationError() }
            guard let value = FieldExtractor.value(for: key, in: cliItem) else {
                throw LargeTypeDisplay.ValidationError.unsupportedRow
            }
            return value
        case .namedAction(let action, _, _):
            return try await resolvedLargeTypeValue(for: action, item: item, generation: generation)
        case .sectionHeader:
            throw LargeTypeDisplay.ValidationError.unsupportedRow
        }
    }

    private func resolvedLargeTypeValue(for action: ItemAction, item: PassItem, generation: Int) async throws -> String {
        switch action {
        case .copyUsername:
            return item.subtitle
        case .copyPassword:
            lastCommand = "\(cliService.cliPath) item view --output json pass://\(item.vaultId)/\(item.id)"
            let detail = try await fetchItem(item.id, item.vaultId)
            try Task.checkCancellation()
            guard isCurrentLargeTypeGeneration(generation) else { throw CancellationError() }
            guard case .login(let login) = detail.content.content else {
                throw LargeTypeDisplay.ValidationError.unsupportedRow
            }
            return login.password
        case .copyTotp:
            lastCommand = "\(cliService.cliPath) item totp --output json pass://\(item.vaultId)/\(item.id)"
            return try await cliService.getTotp(itemId: item.id, shareId: item.vaultId)
        case .openURL, .copyPrimary:
            throw LargeTypeDisplay.ValidationError.unsupportedRow
        }
    }

    private func isCurrentLargeTypeGeneration(_ generation: Int) -> Bool {
        largeTypeGeneration == generation
    }

    private func publishLargeTypeError(_ message: String, generation: Int) {
        guard isCurrentLargeTypeGeneration(generation) else { return }
        errorMessage = message
    }

    private func finishLargeTypeTaskIfCurrent(_ generation: Int) {
        guard isCurrentLargeTypeGeneration(generation) else { return }
        isActionLoading = false
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
