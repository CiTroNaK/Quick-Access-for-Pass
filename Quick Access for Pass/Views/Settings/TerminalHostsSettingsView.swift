import SwiftUI

struct TerminalHostsSettingsView: View {
    let store: TerminalHostStore
    @State private var errorMessage: String?
    @State private var isResetConfirmationPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Terminal Hosts").font(.headline)
            Text("Used by SSH and Run authorization.").font(.caption).foregroundStyle(.secondary)
            if store.configurationError {
                Text("Saved terminal host settings could not be read. Reset them to enable configuration and automatic detection.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Reset Terminal Hosts…") { isResetConfirmationPresented = true }
            } else {
                if !store.entries.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(store.entries) { entry in
                                hostRow(entry)
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                }
                Button("Add Executable…", action: chooseExecutable)
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { store.refreshDetectedHosts() }
        .alert("Reset Saved Terminal Hosts?", isPresented: $isResetConfirmationPresented) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                store.resetInvalidPreferences()
                errorMessage = nil
            }
        } message: {
            Text("This discards unreadable terminal host settings and detects Herdr again. Authorization decisions are not changed.")
        }
    }

    private func hostRow(_ entry: TerminalHostConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Toggle(isOn: binding(for: entry, keyPath: \.isEnabled)) {
                    Text(verbatim: entry.displayName).lineLimit(1).truncationMode(.tail)
                }
                .accessibilityLabel(Text("Enable \(entry.displayName)"))
                if !store.availableIDs.contains(entry.id) {
                    Text("Unavailable").font(.caption).foregroundStyle(.secondary)
                }
                if !entry.isAutomaticallyDetected {
                    Button("Remove") { store.remove(id: entry.id) }
                        .accessibilityLabel(Text("Remove \(entry.displayName)"))
                }
            }
            TextField("Display name", text: binding(for: entry, keyPath: \.displayName))
                .accessibilityLabel(Text("Terminal host name"))
            Text(verbatim: entry.executablePath)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            if entry.provider == .herdr {
                Toggle("Show Herdr pane details", isOn: binding(for: entry, keyPath: \.showPaneDetails))
            }
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func binding<Value>(for entry: TerminalHostConfiguration, keyPath: WritableKeyPath<TerminalHostConfiguration, Value>) -> Binding<Value> {
        Binding(get: {
            store.entries.first(where: { $0.id == entry.id })?[keyPath: keyPath] ?? entry[keyPath: keyPath]
        }, set: { value in
            var updated = store.entries.first(where: { $0.id == entry.id }) ?? entry
            updated[keyPath: keyPath] = value
            do {
                try store.update(updated)
                errorMessage = nil
            } catch {
                errorMessage = message(for: error)
            }
        })
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Add")
        panel.message = String(localized: "Choose a terminal host executable, not an application bundle.")
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try store.addExecutable(at: url)
                errorMessage = nil
            } catch {
                errorMessage = message(for: error)
            }
        }
    }

    private func message(for error: Error) -> String {
        switch error as? TerminalHostStore.StoreError {
        case .invalidPreferences:
            String(localized: "Reset unreadable terminal host settings before making changes.")
        case .invalidExecutable:
            String(localized: "Choose an available executable file.")
        case .duplicateExecutable:
            String(localized: "This executable already has a terminal host mapping.")
        case .invalidEntry:
            String(localized: "Enter a nonempty, single-line terminal host name.")
        case nil:
            String(localized: "Terminal host settings could not be updated.")
        }
    }
}
