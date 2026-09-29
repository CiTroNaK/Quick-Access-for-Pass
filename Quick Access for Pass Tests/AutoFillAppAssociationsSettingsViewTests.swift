import Foundation
import Testing
@testable import Quick_Access_for_Pass

private actor FakeAutoFillAppAssociationSettingsStore: AutoFillAppAssociationSettingsStoring {
    enum Failure: Error {
        case load
        case delete
    }

    var values: [AutoFillAppAssociationDisplay]
    var shouldFailLoading = false
    var shouldFailDeletion = false
    private(set) var deletedServices: [AutoFillServiceIdentifier] = []

    init(values: [AutoFillAppAssociationDisplay] = []) {
        self.values = values
    }

    func associations() async throws -> [AutoFillAppAssociationDisplay] {
        if shouldFailLoading { throw Failure.load }
        return values
    }

    func delete(service: AutoFillServiceIdentifier) async throws {
        if shouldFailDeletion { throw Failure.delete }
        deletedServices.append(service)
        values.removeAll { $0.serviceIdentifier == service.identifier }
    }

    func setLoadingFailure(_ value: Bool) {
        shouldFailLoading = value
    }

    func setDeletionFailure(_ value: Bool) {
        shouldFailDeletion = value
    }
}

@Suite("AutoFill app association settings")
@MainActor
struct AutoFillAppAssociationsSettingsViewTests {
    @Test("refresh renders the empty state")
    func refreshRendersEmptyState() async {
        let model = AutoFillAppAssociationsSettingsModel(store: FakeAutoFillAppAssociationSettingsStore())

        await model.refresh()

        #expect(model.state == .empty)
    }

    @Test("refresh reports a non-secret accessible loading error")
    func refreshReportsFailure() async {
        let store = FakeAutoFillAppAssociationSettingsStore()
        await store.setLoadingFailure(true)
        let model = AutoFillAppAssociationsSettingsModel(store: store)

        await model.refresh()

        #expect(model.state == .failed)
        #expect(model.errorMessage == "Could not load app associations. Try again.")
        #expect(model.errorAccessibilityLabel == "Could not load app associations. Try again.")
    }

    @Test("refresh renders ordered rows with the label and raw identifier separately")
    func refreshRendersOrderedRows() async throws {
        let store = FakeAutoFillAppAssociationSettingsStore(values: [
            try association(identifier: "com.example.second", label: nil, title: "Second", username: "second@example.com", createdAt: 1),
            try association(identifier: "com.example.first", label: "First App", title: "First", username: "first@example.com", createdAt: 2)
        ])
        let model = AutoFillAppAssociationsSettingsModel(store: store)

        await model.refresh()

        guard case .loaded(let associations) = model.state else {
            Issue.record("Expected loaded associations")
            return
        }
        #expect(associations.map(\.service.identifier) == ["com.example.first", "com.example.second"])
        #expect(associations[0].service.displayName == "First App")
        #expect(associations[0].service.identifier == "com.example.first")
        #expect(associations[0].title == "First")
        #expect(associations[0].username == "first@example.com")
    }

    @Test("forget deletes by service and removes the row after refresh")
    func forgetDeletesAssociation() async throws {
        let displayed = try association(identifier: "com.example.app", label: "Example App", title: "Example", username: "user@example.com", createdAt: 1)
        let store = FakeAutoFillAppAssociationSettingsStore(values: [displayed])
        let model = AutoFillAppAssociationsSettingsModel(store: store)
        await model.refresh()

        guard case .loaded(let associations) = model.state, let association = associations.first else {
            Issue.record("Expected one association")
            return
        }
        await model.forget(association)

        #expect(await store.deletedServices == [association.service])
        #expect(model.state == .empty)
    }

    @Test("failed forget retains the visible row and reports an accessible non-secret error")
    func failedForgetRetainsAssociation() async throws {
        let displayed = try association(identifier: "com.example.app", label: nil, title: "Example", username: "user@example.com", createdAt: 1)
        let store = FakeAutoFillAppAssociationSettingsStore(values: [displayed])
        await store.setDeletionFailure(true)
        let model = AutoFillAppAssociationsSettingsModel(store: store)
        await model.refresh()

        guard case .loaded(let associations) = model.state, let association = associations.first else {
            Issue.record("Expected one association")
            return
        }
        await model.forget(association)

        guard case .loaded(let remaining) = model.state else {
            Issue.record("Expected the loaded row to remain")
            return
        }
        #expect(remaining == [association])
        #expect(model.errorMessage == "Could not forget the app association. Try again.")
        #expect(model.errorAccessibilityLabel == "Could not forget the app association. Try again.")
    }

    private func association(
        identifier: String,
        label: String?,
        title: String,
        username: String,
        createdAt: TimeInterval
    ) throws -> AutoFillAppAssociationDisplay {
        AutoFillAppAssociationDisplay(
            serviceIdentifier: identifier,
            serviceDisplayName: label,
            descriptorID: UUID(),
            title: title,
            username: username,
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }
}
