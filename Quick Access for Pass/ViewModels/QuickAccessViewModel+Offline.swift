import Foundation
import SwiftUI

@MainActor
extension QuickAccessViewModel {
    static var offlineSelectionRetryMessage: String {
        String(localized: "Offline status is unavailable. Retry offline setup or status, then try again.")
    }

    var isOfflineOperation: Bool {
        inFlightOfflineOperation != nil
    }


    func handleOfflineAvailability(for item: PassItem) {
        guard let offlineModeCoordinator, !offlineModeCoordinator.isOperating(on: item) else { return }

        inFlightOfflineOperation?.cancel()
        offlineOperationGeneration += 1
        let generation = offlineOperationGeneration
        inFlightOfflineOperation = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.offlineOperationGeneration == generation {
                    self.inFlightOfflineOperation = nil
                }
            }
            do {
                switch offlineModeCoordinator.availability(for: item) {
                case .notCached, .unavailable:
                    try await offlineModeCoordinator.makeAvailableOffline(item)
                case .available, .stale:
                    try await offlineModeCoordinator.removeOfflineItem(itemId: item.id)
                }
            } catch is CancellationError {
                return
            } catch OfflineModeCoordinator.Error.observationUnavailable {
                guard self.offlineOperationGeneration == generation, !Task.isCancelled else { return }
                self.errorMessage = Self.offlineSelectionRetryMessage
            } catch OfflineModeService.Error.selectionSuspended {
                guard self.offlineOperationGeneration == generation, !Task.isCancelled else { return }
                self.errorMessage = Self.offlineSelectionRetryMessage
            } catch {
                guard self.offlineOperationGeneration == generation, !Task.isCancelled else { return }
                self.errorMessage = String(localized: "Failed: \(error.localizedDescription)")
            }
        }
    }

    func handleKeepOfflineIndividually(for item: PassItem) {
        guard let offlineModeCoordinator,
              offlineModeCoordinator.canKeepOfflineIndividually(item.id) else { return }
        offlineOperationGeneration += 1
        let generation = offlineOperationGeneration
        inFlightOfflineOperation = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.offlineOperationGeneration == generation {
                    self.inFlightOfflineOperation = nil
                }
            }
            do {
                try await offlineModeCoordinator.keepOfflineIndividually(item)
                AccessibilityNotification.Announcement(
                    String(localized: "\(item.title) will remain available offline when its vault is turned off.")
                ).post()
            } catch is CancellationError {
                return
            } catch OfflineModeCoordinator.Error.observationUnavailable {
                guard self.offlineOperationGeneration == generation, !Task.isCancelled else { return }
                self.errorMessage = Self.offlineSelectionRetryMessage
            } catch OfflineModeService.Error.selectionSuspended {
                guard self.offlineOperationGeneration == generation, !Task.isCancelled else { return }
                self.errorMessage = Self.offlineSelectionRetryMessage
            } catch {
                guard self.offlineOperationGeneration == generation, !Task.isCancelled else { return }
                self.errorMessage = String(localized: "Could not keep this item offline. Retry offline status and try again.")
            }
        }
    }
}
