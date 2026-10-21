import Foundation

extension OfflineModeCoordinator {
    /// Starts one owned metadata subscription. A fresh lifecycle entry or explicit retry
    /// supersedes its predecessor; body evaluation never creates subscriptions.
    @discardableResult
    func startObservation() -> Task<Void, Never> {
        observationTask?.cancel()
        let generation = UUID()
        observationGeneration = generation
        observationIsFresh = false
        onDetailSelectionInputsChanged?()
        let service = service
        let observation = observation
        let task = Task { [weak self] in
            guard let self, self.observationGeneration == generation, !Task.isCancelled else { return }
            await service.updateSelectionObservation(generation: generation, status: .starting)
            guard self.observationGeneration == generation, !Task.isCancelled else { return }

            guard await self.prepareObservation(service: service, generation: generation) else { return }

            await self.observeSnapshots(observation: observation, service: service, generation: generation)
        }
        observationTask = task
        return task
    }

    func stopObservation() {
        observationTask?.cancel()
        observationTask = nil
        observationGeneration = UUID()
    }

    @discardableResult
    func retryObservation() -> Task<Void, Never> {
        startObservation()
    }

    private func observeSnapshots(
        observation: any OfflineCatalogObserving,
        service: any OfflineModeServicing,
        generation: UUID
    ) async {
        do {
            let stream = observation.snapshots()
            guard self.observationGeneration == generation, !Task.isCancelled else { return }
            for try await presentation in stream {
                guard self.observationGeneration == generation, !Task.isCancelled else { return }
                self.apply(presentation)
                self.observationErrorMessage = nil
                await service.updateSelectionObservation(generation: generation, status: .fresh)
                guard self.observationGeneration == generation, !Task.isCancelled else { return }
                let isReady = await service.isReady()
                guard self.observationGeneration == generation, !Task.isCancelled else { return }
                self.observationIsFresh = isReady && !self.requiresInitializationRetry
                self.onDetailSelectionInputsChanged?()
            }
            guard self.observationGeneration == generation, !Task.isCancelled else { return }
        } catch is CancellationError {
            return
        } catch {
            guard self.observationGeneration == generation, !Task.isCancelled else { return }
            self.observationIsFresh = false
            self.observationErrorMessage = String(localized: "Offline status could not be updated. Retry offline setup.")
            self.onDetailSelectionInputsChanged?()
            await service.updateSelectionObservation(generation: generation, status: .failed)
        }
    }

    private func prepareObservation(service: any OfflineModeServicing, generation: UUID) async -> Bool {
        let needsRetry = await service.requiresInitializationRetry()
        guard self.observationGeneration == generation, !Task.isCancelled else { return false }
        if needsRetry {
            self.requiresInitializationRetry = true
        } else {
            do {
                try await service.initialize()
                guard self.observationGeneration == generation, !Task.isCancelled else { return false }
                self.requiresInitializationRetry = false
            } catch is CancellationError {
                return false
            } catch {
                guard self.observationGeneration == generation, !Task.isCancelled else { return false }
                let requiresRetry = await service.requiresInitializationRetry()
                guard self.observationGeneration == generation, !Task.isCancelled else { return false }
                self.requiresInitializationRetry = requiresRetry
            }
        }

        return observationGeneration == generation && !Task.isCancelled
    }
}
