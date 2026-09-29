import Foundation
import GRDB

/// Non-secret metadata used to create or update one persisted AutoFill descriptor.
nonisolated struct AutoFillDescriptorInput: Codable, Sendable, Equatable {
    let vaultID: String
    let itemID: String
    let shareID: String
    let title: String
    let username: String
    let serviceIdentifier: String
    let hasTOTP: Bool

    var identityKey: AutoFillDescriptorIdentityKey {
        AutoFillDescriptorIdentityKey(
            vaultID: vaultID,
            itemID: itemID,
            serviceIdentifier: serviceIdentifier,
            username: username
        )
    }
}

/// Non-secret source metadata used to derive one descriptor input per normalized web domain.
nonisolated struct AutoFillDescriptorMetadata: Sendable, Equatable {
    let vaultID: String
    let itemID: String
    let shareID: String
    let title: String
    let username: String
    let urls: [String]
    let hasTOTP: Bool
}

/// The fields that keep a descriptor's opaque identifier stable across syncs.
nonisolated struct AutoFillDescriptorIdentityKey: Sendable, Hashable {
    let vaultID: String
    let itemID: String
    let serviceIdentifier: String
    let username: String
}

/// Persisted non-secret metadata for one login and normalized web service.
nonisolated struct AutoFillCredentialDescriptor: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "autoFillDescriptors"

    let id: UUID
    let vaultID: String
    let itemID: String
    let shareID: String
    let title: String
    let username: String
    let serviceIdentifier: String
    let hasTOTP: Bool

    var identityKey: AutoFillDescriptorIdentityKey {
        AutoFillDescriptorIdentityKey(
            vaultID: vaultID,
            itemID: itemID,
            serviceIdentifier: serviceIdentifier,
            username: username
        )
    }

    /// Builds non-secret per-domain descriptor inputs from already projected login metadata.
    static func inputs(for metadata: AutoFillDescriptorMetadata) -> [AutoFillDescriptorInput] {
        Set(metadata.urls.compactMap(normalizedWebDomain))
            .sorted()
            .map { serviceIdentifier in
                AutoFillDescriptorInput(
                    vaultID: metadata.vaultID,
                    itemID: metadata.itemID,
                    shareID: metadata.shareID,
                    title: metadata.title,
                    username: metadata.username,
                    serviceIdentifier: serviceIdentifier,
                    hasTOTP: metadata.hasTOTP
                )
            }
    }

    private static func normalizedWebDomain(from rawURL: String) -> String? {
        guard let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let rawHost = url.host(percentEncoded: false) else {
            return nil
        }

        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty, host.utf8.count <= 253 else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            guard !label.isEmpty,
                  label.utf8.count <= 63,
                  label.first != "-",
                  label.last != "-" else {
                return false
            }
            return label.allSatisfy { character in
                character.isASCII && (character.isLetter || character.isNumber || character == "-")
            }
        }) else {
            return nil
        }
        return host
    }
}
