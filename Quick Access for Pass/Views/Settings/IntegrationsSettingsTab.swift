import SwiftUI

/// Settings for explicitly supported integrations and user-defined terminal mappings.
struct IntegrationsSettingsTab: View {
    let store: TerminalHostStore
    @State private var editor: TerminalHostEditorModel?
    @State private var isResetConfirmationPresented = false

    var body: some View {
        SettingsLayout.settingsPane {
            VStack(alignment: .leading, spacing: 12) {
                Text("Integrations").font(.headline)
                Text("Optional integrations used by SSH and Run authorization.")
                    .font(.caption).foregroundStyle(.secondary)

                GroupBox("Supported apps") {
                    VStack(alignment: .leading, spacing: 10) {
                        herdrSection
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Custom terminal hosts") {
                    VStack(alignment: .leading, spacing: 10) {
                        if store.configurationError {
                            Text("Saved terminal host settings could not be read. Reset them to enable configuration and automatic detection.")
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Reset Terminal Hosts…") { isResetConfirmationPresented = true }
                        } else {
                            customHosts
                            Button("Add Custom Terminal…") { presentEditor() }
                                .disabled(store.configurationError)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .onAppear { store.refreshDetectedHosts() }
            .sheet(isPresented: editorPresented) {
                if let editor {
                    TerminalHostEditorSheet(model: editor, onCancel: { self.editor = nil }, onSave: { self.editor = nil })
                }
            }
            .alert("Reset Saved Terminal Hosts?", isPresented: $isResetConfirmationPresented) {
                Button("Cancel", role: .cancel) { }
                Button("Reset", role: .destructive) { store.resetInvalidPreferences() }
            } message: {
                Text("This discards unreadable terminal host settings and detects Herdr again. Authorization decisions are not changed.")
            }
        }
    }

    @ViewBuilder private var herdrSection: some View {
        let entry = store.entries.first(where: { $0.id == SupportedTerminalHost.herdr.rawValue })
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(SupportedTerminalHost.herdr.displayName).font(.body.weight(.medium))
                Text(herdrStatus(entry))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let entry {
                    Text(verbatim: entry.executablePath)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            if let entry {
                Button("Edit") { presentEditor(entryID: entry.id) }
                    .disabled(store.configurationError)
            }
        }
        if let entry {
            Toggle("Enable Herdr", isOn: binding(for: entry, keyPath: \.isEnabled))
                .disabled(store.configurationError)
            Toggle("Show Herdr pane details", isOn: binding(for: entry, keyPath: \.showPaneDetails))
                .disabled(store.configurationError)
        } else {
            Text("Herdr is not configured.").font(.caption).foregroundStyle(.secondary)
        }
        if store.hasCustomHerdrOverride {
            Label("A custom mapping uses the Herdr path; automatic Herdr details are disabled.", systemImage: "arrow.trianglehead.2.clockwise")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var customHosts: some View {
        let entries = store.entries.filter { $0.provider == .generic }
        if entries.isEmpty {
            Text("No custom terminal hosts.").font(.caption).foregroundStyle(.secondary)
        } else {
            Group {
                if entries.count > 2 {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(entries) { customHostRow($0) }
                        }
                    }
                    .frame(maxHeight: 150)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(entries) { customHostRow($0) }
                    }
                }
            }
        }
    }

    private func customHostRow(_ entry: TerminalHostConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Toggle(isOn: binding(for: entry, keyPath: \.isEnabled)) {
                    Text(verbatim: entry.displayName).lineLimit(1).truncationMode(.tail)
                }
                .accessibilityLabel(Text("Enable \(entry.displayName)"))
                .disabled(store.configurationError)
                if !store.availableIDs.contains(entry.id) {
                    Text("Unavailable").font(.caption).foregroundStyle(.secondary)
                }
                Button("Edit") { presentEditor(entryID: entry.id) }
                    .disabled(store.configurationError)
                Button("Remove", role: .destructive) { store.remove(id: entry.id) }
                    .accessibilityLabel(Text("Remove \(entry.displayName)"))
                    .disabled(store.configurationError)
            }
            Text(verbatim: entry.executablePath)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func herdrStatus(_ entry: TerminalHostConfiguration?) -> String {
        guard let entry else { return String(localized: "Not configured") }
        if store.hasCustomHerdrOverride { return String(localized: "Custom override") }
        return store.availableIDs.contains(entry.id)
            ? String(localized: "Installed") : String(localized: "Unavailable")
    }

    private var editorPresented: Binding<Bool> {
        Binding(get: { editor != nil }, set: { if !$0 { editor = nil } })
    }

    private func presentEditor(entryID: String? = nil) {
        editor = TerminalHostEditorModel(store: store, entryID: entryID)
    }

    private func binding<Value>(for entry: TerminalHostConfiguration, keyPath: WritableKeyPath<TerminalHostConfiguration, Value>) -> Binding<Value> {
        Binding(get: {
            store.entries.first(where: { $0.id == entry.id })?[keyPath: keyPath] ?? entry[keyPath: keyPath]
        }, set: { value in
            guard var updated = store.entries.first(where: { $0.id == entry.id }) else { return }
            updated[keyPath: keyPath] = value
            try? store.update(updated)
        })
    }
}
