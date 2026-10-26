import Foundation

@MainActor
extension QuickAccessViewModel {
    /// Observation triggers redraws, but current synchronous gate evidence decides visibility.
    var folderPresentationAvailability: FolderFeatureAvailability {
        _ = folderAvailability
        return cliService.folderFeatureGate.availability
    }

    /// Reading observed values here refreshes the enclosing results-list inputs, including its stamp.
    var folderPresentationStamp: FolderFeatureStamp? {
        _ = folderLocationsByItemID
        guard folderPresentationAvailability == .supported, let stamp = folderLocationsStamp,
              cliService.folderFeatureGate.isCurrent(stamp) else { return nil }
        return stamp
    }

    func folderLocation(for itemID: String) -> FolderLocationPresentation? {
        guard folderPresentationAvailability == .supported, let stamp = folderLocationsStamp,
              cliService.folderFeatureGate.isCurrent(stamp) else { return nil }
        return folderLocationsByItemID[itemID]
    }

    func startObservingFolderFeature() {
        let gate = cliService.folderFeatureGate
        folderAvailability = gate.availability
        folderObservedStamp = gate.supportedStamp()
        let updates = gate.updates()
        folderFeatureObservationTask = Task { [weak self] in
            for await _ in updates {
                guard !Task.isCancelled else { break }
                self?.folderFeatureDidChange()
            }
        }
    }

    private func folderFeatureDidChange() {
        let gate = cliService.folderFeatureGate
        let availability = gate.availability
        let stamp = gate.supportedStamp()
        guard availability != folderAvailability || stamp != folderObservedStamp else { return }
        folderAvailability = availability
        folderObservedStamp = stamp
        refreshFolderLocations()
    }

    func invalidateFolderLocations() {
        folderLoadGeneration += 1
        folderLocationsTask?.cancel()
        folderLocationsTask = nil
        folderLocationsStamp = nil
        folderLocationsByItemID = [:]
    }

    func refreshFolderLocations() {
        invalidateFolderLocations()
        let gate = cliService.folderFeatureGate
        guard let query = folderResultsQuery, let stamp = gate.supportedStamp() else { return }
        let generation = folderLoadGeneration
        let itemIDs = Set(items.map(\.id))
        let loader = folderLocationLoader
        // Retain only request metadata while awaiting. Neither task nor gate observes secret content.
        folderLocationsTask = Task { [weak self] in
            do {
                let locations = try await loader(itemIDs)
                guard !Task.isCancelled, gate.isCurrent(stamp), let self,
                      self.folderLoadGeneration == generation, self.folderResultsQuery == query else { return }
                self.folderLocationsStamp = stamp
                self.folderLocationsByItemID = locations.filter { itemIDs.contains($0.key) }
            } catch {
                // Missing presentation context must never fail ordinary search or produce guessed paths.
            }
        }
    }
}
