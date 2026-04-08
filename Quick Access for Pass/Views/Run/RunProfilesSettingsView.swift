import SwiftUI

struct RunProfilesSettingsView: View {
    let databaseManager: DatabaseManager
    @State private var profiles: [RunProfile] = []
    @State private var editingState: EditingState?

    /// Wraps profile + mappings into a single Identifiable value for sheet(item:).
    struct EditingState: Identifiable {
        let id = UUID()
        let profile: RunProfile
        let mappings: [RunProfileEnvMapping]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Run Profiles")
                .foregroundStyle(.secondary)

            ForEach(profiles) { profile in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(profile.name)
                            .font(.callout)
                        Text(profile.slug)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button {
                        guard let profileId = profile.id else { return }
                        editingState = EditingState(
                            profile: profile,
                            mappings: (try? databaseManager.envMappings(forProfileId: profileId)) ?? []
                        )
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Edit profile"))
                    Button {
                        guard let profileId = profile.id else { return }
                        try? databaseManager.deleteRunProfile(id: profileId)
                        loadProfiles()
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Delete profile"))
                }
            }

            if profiles.isEmpty {
                Text("No profiles configured.")
                    .font(.caption)
                    .foregroundStyle(.quaternary)
            }

            Button("Add Profile") {
                editingState = EditingState(
                    profile: RunProfile(id: nil, name: "", slug: "", cacheDuration: RememberDuration.fiveMinutes.rawValue, createdAt: Date()),
                    mappings: []
                )
            }
        }
        .onAppear { loadProfiles() }
        .sheet(item: $editingState) { state in
            RunProfileEditorView(
                databaseManager: databaseManager,
                profile: state.profile,
                mappings: state.mappings
            ) {
                editingState = nil
                loadProfiles()
            }
        }
    }

    private func loadProfiles() {
        profiles = (try? databaseManager.allRunProfiles()) ?? []
    }
}

// MARK: - Profile Editor Sheet

struct RunProfileEditorView: View {
    let databaseManager: DatabaseManager
    let profileId: Int64?
    let profileCreatedAt: Date
    @State var name: String
    @State var mappings: [EditableMapping]
    let onDismiss: () -> Void

    struct EditableMapping: Identifiable {
        let id = UUID()
        var envVariable: String
        var secretReference: String
    }

    @State var cacheDuration: RememberDuration

    init(databaseManager: DatabaseManager, profile: RunProfile, mappings: [RunProfileEnvMapping], onDismiss: @escaping () -> Void) {
        self.databaseManager = databaseManager
        self.profileId = profile.id
        self.profileCreatedAt = profile.createdAt
        self._name = State(initialValue: profile.name)
        self._cacheDuration = State(initialValue: RememberDuration(rawValue: profile.cacheDuration) ?? .fiveMinutes)
        self._mappings = State(initialValue: mappings.map {
            EditableMapping(envVariable: $0.envVariable, secretReference: $0.secretReference)
        })
        self.onDismiss = onDismiss
    }

    private var slug: String {
        name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    private var canSave: Bool {
        !name.isEmpty && !mappings.isEmpty && mappings.allSatisfy {
            !$0.envVariable.isEmpty && $0.secretReference.hasPrefix("pass://")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(profileId == nil ? "New Profile" : "Edit Profile")
                .font(.headline)

            HStack {
                Text("Name")
                    .foregroundStyle(.secondary)
                TextField("e.g., GitHub CLI", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Text("Slug")
                    .foregroundStyle(.secondary)
                Text(slug)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Text("Cache secrets for")
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $cacheDuration) {
                    ForEach(RememberDuration.allCases) { duration in
                        Text(duration.localizedLabel).tag(duration)
                    }
                }
                .frame(width: 180)
            }

            Divider()

            Text("Environment Mappings")
                .foregroundStyle(.secondary)

            ForEach($mappings) { $mapping in
                HStack(spacing: 4) {
                    TextField("ENV_VAR", text: $mapping.envVariable)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                    Text("=")
                        .foregroundStyle(.tertiary)
                    TextField("pass://vault/item/field", text: $mapping.secretReference)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        mappings.removeAll { $0.id == mapping.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Remove mapping"))
                }
            }

            Button("Add Mapping") {
                mappings.append(EditableMapping(envVariable: "", secretReference: ""))
            }

            Divider()

            HStack {
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private func save() {
        let toSave = RunProfile(
            id: profileId,
            name: name,
            slug: slug,
            cacheDuration: cacheDuration.rawValue,
            createdAt: profileId == nil ? Date() : profileCreatedAt
        )
        let envMappings = mappings.map {
            RunProfileEnvMapping(id: nil, profileId: 0, envVariable: $0.envVariable, secretReference: $0.secretReference)
        }
        _ = try? databaseManager.saveRunProfile(toSave, mappings: envMappings)
        onDismiss()
    }
}
