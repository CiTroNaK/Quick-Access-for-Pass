import SwiftUI

struct SSHVaultFilterView: View {
    @Environment(\.databaseManager) private var databaseManager
    @AppStorage(DefaultsKey.sshVaultFilter) private var filterJSON: String = "[]"
    @State private var availableVaults: [String] = []

    private var selectedVaults: Set<String> {
        Set((try? JSONDecoder().decode([String].self, from: Data(filterJSON.utf8))) ?? [])
    }

    private func saveSelection(_ set: Set<String>) {
        if let data = try? JSONEncoder().encode(Array(set)) {
            filterJSON = String(data: data, encoding: .utf8) ?? "[]"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Limit to vaults")
                    .foregroundStyle(.secondary)
                Spacer()
            }

            ForEach(availableVaults, id: \.self) { name in
                Toggle(name, isOn: binding(for: name))
                    .toggleStyle(.checkbox)
            }

            Text("Only keys from selected vaults will be available. Empty = all vaults.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .onAppear { loadVaults() }
    }

    private func loadVaults() {
        availableVaults = ((try? databaseManager?.allVaults()) ?? [])
            .map(\.name)
            .sorted()
    }

    private func binding(for name: String) -> Binding<Bool> {
        Binding(
            get: { selectedVaults.contains(name) },
            set: { isOn in
                var set = selectedVaults
                if isOn { set.insert(name) } else { set.remove(name) }
                saveSelection(set)
            }
        )
    }
}
