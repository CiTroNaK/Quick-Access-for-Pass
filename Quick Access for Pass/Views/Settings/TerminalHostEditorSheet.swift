import SwiftUI
import AppKit

/// Presents paste-friendly terminal host fields; choosing a path never saves it.
struct TerminalHostEditorSheet: View {
    @Bindable var model: TerminalHostEditorModel
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.entryID == nil ? "Add Custom Terminal" : "Edit Terminal")
                .font(.headline)
            TextField("Display name", text: $model.displayName)
                .accessibilityLabel(Text("Display name"))
            if !model.isNameOnly {
                HStack(spacing: 8) {
                    TextField("Executable path", text: $model.executablePath)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(Text("Executable path"))
                    Button("Choose…", action: chooseExecutable)
                }
                Text("Paste an absolute path or a path beginning with ~/.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(model.entryID == nil ? "Add" : "Save") {
                    if model.save() { onSave() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose a terminal host executable, not an application bundle.")
        if panel.runModal() == .OK, let url = panel.url {
            model.executablePath = url.path
        }
    }
}
