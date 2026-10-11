import Foundation
import Observation

@MainActor @Observable final class TerminalHostStore {
    private nonisolated struct Envelope: Codable {
        let version: Int
        let entries: [TerminalHostConfiguration]
    }

    enum StoreError: Error {
        case invalidPreferences, invalidExecutable, duplicateExecutable, invalidEntry
    }

    private struct EffectiveState: Equatable {
        let entries: [TerminalHostConfiguration]
        let canonicalPaths: [String]
        let availableIDs: Set<String>
    }

    private let defaults: UserDefaults
    private let discovery: TerminalHostDiscovery
    private(set) var entries: [TerminalHostConfiguration] = []
    private(set) var revision: UInt64 = 0
    private(set) var configurationError = false
    @ObservationIgnored private var observers: [UUID: @MainActor () -> Void] = [:]
    @ObservationIgnored private var lastEffectiveState: EffectiveState?

    init(defaults: UserDefaults, discovery: TerminalHostDiscovery) {
        self.defaults = defaults
        self.discovery = discovery
        if let saved = defaults.object(forKey: DefaultsKey.terminalHosts) {
            do {
                guard let data = saved as? Data else { throw StoreError.invalidPreferences }
                let envelope = try JSONDecoder().decode(Envelope.self, from: data)
                guard envelope.version == 1, Self.isValid(envelope.entries) else { throw StoreError.invalidPreferences }
                entries = envelope.entries
            } catch {
                configurationError = true
            }
        }
        refreshDetectedHosts()
    }

    var availableIDs: Set<String> {
        // Refresh changes revision even when preferences did not change (e.g. a removed installation).
        _ = revision
        return Set(entries.filter { discovery.isExecutableRegularFile(URL(fileURLWithPath: $0.executablePath)) }.map(\.id))
    }

    /// Enabled presentation mappings. Even disabled generic mappings mask automatic Herdr activation.
    /// Availability is separate from saved consent; callers must use this view, not raw entries, for matching.
    var effectiveEntries: [TerminalHostConfiguration] {
        _ = revision
        guard !configurationError else { return [] }
        let genericPaths = Set(entries.filter { $0.provider == .generic }.map { canonicalPath($0) })
        return entries.filter {
            $0.isEnabled && !($0.isAutomaticallyDetected && genericPaths.contains(canonicalPath($0)))
        }
    }

    /// Pure resolver input; canonical paths are derived here, never persisted.
    var matchingEntries: [TerminalHostMatchingEntry] {
        effectiveEntries.map { .init(configuration: $0, canonicalExecutablePath: canonicalPath($0)) }
    }

    func refreshDetectedHosts() {
        guard !configurationError else { return }
        let previous = entries
        if let url = discovery.discoverHerdr() { applyDetectedHerdr(at: url) }
        finishChange(previousEntries: previous)
    }

    func addExecutable(at url: URL) throws {
        guard !configurationError else { throw StoreError.invalidPreferences }
        guard discovery.isExecutableRegularFile(url) else { throw StoreError.invalidExecutable }
        guard !hasDuplicatePath(url, excluding: nil) else { throw StoreError.duplicateExecutable }
        let entry = TerminalHostConfiguration(
            id: UUID().uuidString, executablePath: url.standardizedFileURL.path,
            displayName: url.deletingPathExtension().lastPathComponent, isEnabled: true,
            provider: .generic, showPaneDetails: false, isAutomaticallyDetected: false
        )
        guard Self.isValid([entry]) else { throw StoreError.invalidEntry }
        let previous = entries
        entries.append(entry)
        finishChange(previousEntries: previous)
    }

    func update(_ entry: TerminalHostConfiguration) throws {
        guard !configurationError else { throw StoreError.invalidPreferences }
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { throw StoreError.invalidEntry }
        var updated = entry
        // Provider and discovery provenance belong to the store, never to ordinary preference edits.
        updated.provider = entries[index].provider
        updated.isAutomaticallyDetected = entries[index].isAutomaticallyDetected
        guard Self.isValid([updated]) else { throw StoreError.invalidEntry }
        if updated.executablePath != entries[index].executablePath {
            let url = URL(fileURLWithPath: updated.executablePath)
            guard discovery.isExecutableRegularFile(url) else { throw StoreError.invalidExecutable }
            guard !hasDuplicatePath(url, excluding: updated.id) else { throw StoreError.duplicateExecutable }
            updated.executablePath = url.standardizedFileURL.path
        }
        let previous = entries
        entries[index] = updated
        finishChange(previousEntries: previous)
    }

    func remove(id: String) {
        guard !configurationError else { return }
        let previous = entries
        if id == "herdr", let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].isEnabled = false
        } else {
            entries.removeAll { $0.id == id }
        }
        finishChange(previousEntries: previous)
    }

    func observeExecutable(at url: URL) {
        guard !configurationError, url.lastPathComponent == "herdr", discovery.isExecutableRegularFile(url) else { return }
        let previous = entries
        applyDetectedHerdr(at: url.standardizedFileURL)
        finishChange(previousEntries: previous)
    }

    func resetInvalidPreferences() {
        guard configurationError else { return }
        configurationError = false
        entries = []
        if let url = discovery.discoverHerdr() { applyDetectedHerdr(at: url) }
        persist()
        notifyChanges()
    }

    /// Subscribers should capture their owners weakly and remove the token on explicit dismissal/cancellation.
    func observeChanges(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    func removeObserver(_ token: UUID) { observers.removeValue(forKey: token) }

    private func applyDetectedHerdr(at url: URL) {
        if let index = entries.firstIndex(where: { $0.id == "herdr" }) {
            // Retain choices even when an upgrade now collides with a generic mapping.
            entries[index].executablePath = url.path
        } else if !entries.contains(where: { $0.provider == .generic && canonicalPath($0) == discovery.canonicalPath(for: url) }) {
            entries.append(.init(id: "herdr", executablePath: url.path, displayName: "Herdr", isEnabled: true,
                                 provider: .herdr, showPaneDetails: true, isAutomaticallyDetected: true))
        }
    }

    private func canonicalPath(_ entry: TerminalHostConfiguration) -> String {
        discovery.canonicalPath(for: URL(fileURLWithPath: entry.executablePath))
    }

    private func hasDuplicatePath(_ url: URL, excluding id: String?) -> Bool {
        entries.contains { $0.id != id && canonicalPath($0) == discovery.canonicalPath(for: url) }
    }

    private var effectiveState: EffectiveState {
        EffectiveState(entries: effectiveEntries, canonicalPaths: effectiveEntries.map { canonicalPath($0) }, availableIDs: availableIDs)
    }

    private func finishChange(previousEntries: [TerminalHostConfiguration]) {
        let preferencesChanged = previousEntries != entries
        if preferencesChanged { persist() }
        if preferencesChanged || lastEffectiveState != effectiveState { notifyChanges() }
    }

    private func persist() {
        // All fields are structurally validated and JSON-encodable value types.
        do {
            let data = try JSONEncoder().encode(Envelope(version: 1, entries: entries))
            defaults.set(data, forKey: DefaultsKey.terminalHosts)
        } catch {
            preconditionFailure("Validated terminal host preferences must be JSON-encodable")
        }
    }

    private func notifyChanges() {
        lastEffectiveState = effectiveState
        revision &+= 1
        // Snapshot callbacks so observers can remove themselves during notification.
        for handler in Array(observers.values) { handler() }
    }

    private static func isValid(_ entries: [TerminalHostConfiguration]) -> Bool {
        guard Set(entries.map(\.id)).count == entries.count else { return false }
        return entries.allSatisfy {
            !$0.id.isEmpty && $0.executablePath.hasPrefix("/") &&
            $0.executablePath.rangeOfCharacter(from: .controlCharacters) == nil &&
            !$0.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            $0.displayName.rangeOfCharacter(from: .newlines) == nil &&
            ($0.id == "herdr" ? ($0.provider == .herdr && $0.isAutomaticallyDetected) :
                ($0.provider == .generic && !$0.isAutomaticallyDetected))
        }
    }
}
