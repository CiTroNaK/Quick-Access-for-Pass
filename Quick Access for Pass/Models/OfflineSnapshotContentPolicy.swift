import Foundation

/// Immutable, cumulative content contracts, independent for each offline item type.
nonisolated struct OfflineSnapshotContentPolicy: Sendable {
    /// A synchronous content check. Production predicates never capture fetched items or perform I/O.
    typealias Requirement = @Sendable (CLIItem) -> Bool

    /// Current capture contracts; append requirements without changing earlier revision meanings.
    static let current = OfflineSnapshotContentPolicy(requirements: [
        .alias: [{ item in
            guard let email = item.aliasEmail else { return false }
            return !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }]
    ])

    private let requirements: [ItemType: [Requirement]]

    /// Creates independent, ordered contracts; each predicate's one-based position is its revision.
    init(requirements: [ItemType: [Requirement]]) {
        self.requirements = requirements
    }

    /// Returns the required revision, or zero when the type has no additional content contracts.
    func requiredRevision(for itemType: ItemType) -> Int {
        requirements[itemType]?.count ?? 0
    }

    /// Returns the highest consecutive revision satisfied by the actual item's content.
    func satisfiedRevision(for item: CLIItem) -> Int {
        var revision = 0
        for requirement in requirements[item.content.content.itemType] ?? [] {
            guard requirement(item) else { break }
            revision += 1
        }
        return revision
    }

    /// Compares a certified revision with its type's requirement; never grants access or ownership.
    func needsRefresh(contentRevision: Int, for itemType: ItemType) -> Bool {
        contentRevision < requiredRevision(for: itemType)
    }
}
