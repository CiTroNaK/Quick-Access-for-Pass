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
        VStack(alignment: .leading, spacing: 8) {
            Text("Limit to vaults")
                .font(.body)

            ForEach(availableVaults, id: \.self) { name in
                SettingsLayout.settingsRow(label: LocalizedStringKey(name)) {
                    Toggle(name, isOn: binding(for: name))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            Text("Only keys from selected vaults will be available. Empty = all vaults.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { loadVaults() }
    }

    private func loadVaults() {
        availableVaults = ((try? databaseManager?.allVaults()) ?? [])
            .sorted { lhs, rhs in
                lhs.name == rhs.name
                    ? lhs.id < rhs.id
                    : lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .map(\.name)
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
