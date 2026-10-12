import SwiftUI

/// Settings for explicitly supported integrations and user-defined terminal mappings.
struct IntegrationsSettingsTab: View {
    let store: TerminalHostStore
    @State private var editor: TerminalHostEditorModel?
    @State private var isResetConfirmationPresented = false

    var body: some View {
        SettingsLayout.settingsPane {
            VStack(alignment: .leading, spacing: 8) {
                Text("Supported apps").font(.body)
                Text("Identify requests from supported terminal hosts and show their context in SSH and Run dialogs.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                herdrSection

                Text("Context is best-effort and informational. It never changes permission scope. Herdr is the only pane-detail integration currently supported.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)

                HStack {
                    Text("Custom terminal hosts").font(.body)
                    Spacer()
                    if !store.configurationError {
                        Button("Add…") { presentEditor() }
                            .disabled(store.configurationError)
                    }
                }
                .padding(.top, 10)

                if store.configurationError {
                    Text("Saved terminal host settings could not be read. Reset them to enable configuration and automatic detection.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Reset Terminal Hosts…") { isResetConfirmationPresented = true }
                } else {
                    customHosts
                    Text("Map another executable to a display name. Custom mappings do not run the executable or read pane details.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
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
        HStack(spacing: 10) {
            Image(systemName: "terminal")
                .font(.system(size: 18))
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(SupportedTerminalHost.herdr.displayName).font(.body)
                    Text(herdrStatus(entry))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let entry {
                    Text(verbatim: entry.executablePath)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
            Spacer(minLength: 6)
            if let entry {
                Toggle("Enable Herdr", isOn: binding(for: entry, keyPath: \.isEnabled))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(Text("Enable Herdr"))
                    .disabled(store.configurationError)
                Button("Edit…") { presentEditor(entryID: entry.id) }
                    .disabled(store.configurationError)
            } else {
                Text("Herdr is not configured.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)

        if let entry {
            SettingsLayout.settingsRow(label: "Show workspace, pane title and directory") {
                Toggle("Show Herdr pane details", isOn: binding(for: entry, keyPath: \.showPaneDetails))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(Text("Show Herdr pane details"))
                    .disabled(store.configurationError)
            }
        }
        if store.hasCustomHerdrOverride {
            Label("A custom mapping uses the Herdr path; automatic Herdr details are disabled.", systemImage: "arrow.trianglehead.2.clockwise")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Divider()
    }

    @ViewBuilder private var customHosts: some View {
        let entries = store.entries.filter { $0.provider == .generic }
        if entries.isEmpty {
            Text("No custom terminal hosts.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        } else if entries.count > 2 {
            ScrollView {
                customHostRows(entries)
            }
            .frame(maxHeight: 150)
        } else {
            customHostRows(entries)
        }
    }

    private func customHostRows(_ entries: [TerminalHostConfiguration]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                customHostRow(entry)
                if index < entries.count - 1 { Divider() }
            }
        }
    }

    private func customHostRow(_ entry: TerminalHostConfiguration) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: entry.displayName).lineLimit(1).truncationMode(.tail)
                    if !store.availableIDs.contains(entry.id) {
                        Text("Unavailable").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(verbatim: entry.executablePath)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Toggle(isOn: binding(for: entry, keyPath: \.isEnabled)) {
                Text(verbatim: entry.displayName)
            }
            .labelsHidden()
            .toggleStyle(.switch)
            .accessibilityLabel(Text("Enable \(entry.displayName)"))
            .disabled(store.configurationError)
            Button("Edit…") { presentEditor(entryID: entry.id) }
                .disabled(store.configurationError)
            Button("Remove", role: .destructive) { store.remove(id: entry.id) }
                .accessibilityLabel(Text("Remove \(entry.displayName)"))
                .disabled(store.configurationError)
        }
        .padding(.vertical, 6)
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
