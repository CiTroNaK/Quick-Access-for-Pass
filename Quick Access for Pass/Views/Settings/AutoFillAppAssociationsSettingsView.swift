import Foundation
import Observation
import SwiftUI

nonisolated protocol AutoFillAppAssociationSettingsStoring: Sendable {
    func associations() async throws -> [AutoFillAppAssociationDisplay]
    func delete(service: AutoFillServiceIdentifier) async throws
}

extension AutoFillAppAssociationStore: AutoFillAppAssociationSettingsStoring {}

nonisolated struct AutoFillAppAssociationSettingsRow: Equatable, Sendable, Identifiable {
    let service: AutoFillServiceIdentifier
    let descriptorID: UUID
    let title: String
    let username: String
    let createdAt: Date

    var id: String { service.identifier }

    init?(_ display: AutoFillAppAssociationDisplay) {
        guard let service = try? AutoFillServiceIdentifier(
            kind: .app,
            identifier: display.serviceIdentifier,
            displayName: display.serviceDisplayName
        ) else {
            return nil
        }
        self.service = service
        self.descriptorID = display.descriptorID
        self.title = display.title
        self.username = display.username
        self.createdAt = display.createdAt
    }
}

@MainActor
@Observable
final class AutoFillAppAssociationsSettingsModel {
    enum State: Equatable {
        case loading
        case loaded([AutoFillAppAssociationSettingsRow])
        case empty
        case failed
    }

    private let store: any AutoFillAppAssociationSettingsStoring
    private var operationTask: Task<Void, Never>?
    private var generation = 0

    var state: State = .loading
    var errorMessage: String?
    var statusMessage: String?
    var deletingServiceIdentifier: String?

    var associations: [AutoFillAppAssociationSettingsRow] {
        guard case .loaded(let associations) = state else { return [] }
        return associations
    }

    var errorAccessibilityLabel: String? { errorMessage }

    init(store: any AutoFillAppAssociationSettingsStoring) {
        self.store = store
    }

    isolated deinit {
        operationTask?.cancel()
    }

    func refresh() async {
        operationTask?.cancel()
        generation &+= 1
        let currentGeneration = generation
        let store = store
        state = .loading
        deletingServiceIdentifier = nil
        errorMessage = nil

        let task = Task { [weak self] in
            do {
                let displays = try await store.associations()
                try Task.checkCancellation()
                guard let self, self.generation == currentGeneration else { return }
                let associations = Self.ordered(displays)
                self.state = associations.isEmpty ? .empty : .loaded(associations)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.generation == currentGeneration else { return }
                self.state = .failed
                self.errorMessage = String(localized: "Could not load app associations. Try again.")
                self.announce(self.errorMessage)
            }
        }
        operationTask = task
        await task.value
        if generation == currentGeneration {
            operationTask = nil
        }
    }

    func forget(_ association: AutoFillAppAssociationSettingsRow) async {
        operationTask?.cancel()
        generation &+= 1
        let currentGeneration = generation
        let store = store
        let priorState = state
        deletingServiceIdentifier = association.service.identifier
        errorMessage = nil
        statusMessage = nil

        let task = Task { [weak self] in
            do {
                try await store.delete(service: association.service)
                let displays = try await store.associations()
                try Task.checkCancellation()
                guard let self, self.generation == currentGeneration else { return }
                let associations = Self.ordered(displays)
                self.state = associations.isEmpty ? .empty : .loaded(associations)
                self.deletingServiceIdentifier = nil
                self.statusMessage = String(localized: "App association forgotten.")
                self.announce(self.statusMessage)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.generation == currentGeneration else { return }
                self.state = priorState
                self.deletingServiceIdentifier = nil
                self.errorMessage = String(localized: "Could not forget the app association. Try again.")
                self.announce(self.errorMessage)
            }
        }
        operationTask = task
        await task.value
        if generation == currentGeneration {
            operationTask = nil
        }
    }

    private static func ordered(
        _ displays: [AutoFillAppAssociationDisplay]
    ) -> [AutoFillAppAssociationSettingsRow] {
        displays.compactMap(AutoFillAppAssociationSettingsRow.init)
            .sorted {
                $0.createdAt == $1.createdAt
                    ? $0.service.identifier < $1.service.identifier
                    : $0.createdAt > $1.createdAt
            }
    }

    private func announce(_ message: String?) {
        guard let message else { return }
        AccessibilityNotification.Announcement(message).post()
    }
}

struct AutoFillAppAssociationsSettingsView: View {
    @Bindable var model: AutoFillAppAssociationsSettingsModel
    @State private var associationPendingDeletion: AutoFillAppAssociationSettingsRow?
    @FocusState private var focusedServiceIdentifier: String?
    @AccessibilityFocusState private var accessibilityFocusedServiceIdentifier: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AutoFill app associations")
                .font(.headline)

            switch model.state {
            case .loading:
                ProgressView("Loading app associations")
                    .controlSize(.small)
            case .empty:
                Text("No app associations are remembered.")
                    .foregroundStyle(.secondary)
            case .failed:
                Text("App associations could not be loaded.")
                    .foregroundStyle(.secondary)
            case .loaded(let associations):
                ForEach(associations) { association in
                    associationRow(association)
                }
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel(model.errorAccessibilityLabel ?? errorMessage)
            }
            if let statusMessage = model.statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.green)
                    .accessibilityLabel(statusMessage)
            }
        }
        .confirmationDialog(
            "Forget this app association?",
            isPresented: Binding(
                get: { associationPendingDeletion != nil },
                set: { if !$0 { associationPendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: associationPendingDeletion
        ) { association in
            Button("Forget association", role: .destructive) {
                associationPendingDeletion = nil
                Task {
                    await model.forget(association)
                    guard model.statusMessage != nil else { return }
                    focusedServiceIdentifier = model.associations.first?.service.identifier
                    accessibilityFocusedServiceIdentifier = model.associations.first?.service.identifier
                }
            }
            Button("Cancel", role: .cancel) {
                associationPendingDeletion = nil
            }
        } message: { association in
            Text("This stops Quick Access from preferring \(association.title) for \(association.service.identifier).")
        }
        .task {
            await model.refresh()
        }
    }

    @ViewBuilder
    private func associationRow(_ association: AutoFillAppAssociationSettingsRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let label = association.service.displayName, !label.isEmpty {
                Text(label)
                    .font(.subheadline.weight(.medium))
            }
            Text(association.service.identifier)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("\(association.title) — \(association.username)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Forget association", role: .destructive) {
                associationPendingDeletion = association
            }
            .accessibilityLabel("Forget association for \(association.service.identifier)")
            .accessibilityHint("Removes the remembered AutoFill login for this app")
            .focused($focusedServiceIdentifier, equals: association.service.identifier)
            .accessibilityFocused($accessibilityFocusedServiceIdentifier, equals: association.service.identifier)
            .disabled(model.deletingServiceIdentifier != nil)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}
