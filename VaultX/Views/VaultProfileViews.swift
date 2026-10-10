import SwiftUI

// MARK: - Palette

extension VaultProfile {

    static func color(for key: String) -> Color {

        switch key {
        case "indigo": return .indigo
        case "purple": return .purple
        case "pink": return .pink
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "teal": return .teal
        case "gray": return .gray
        default: return .blue
        }
    }

    var swiftUIColor: Color {
        Self.color(for: color)
    }
}

/// Quadrato colorato con l'icona del vault.
struct VaultIconBadge: View {

    let profile: VaultProfile

    var size: CGFloat = 44

    var body: some View {

        Image(systemName: profile.icon)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                profile.swiftUIColor.gradient,
                in: RoundedRectangle(
                    cornerRadius: size * 0.23,
                    style: .continuous
                )
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Fields (shared by "new vault" and "properties")

/// Sezione di un `Form` per scegliere modello, icona, colore e descrizione.
struct VaultProfileFields: View {

    @Binding var profile: VaultProfile

    var showsPresets = true

    private var currentPreset: VaultProfile.Preset {

        VaultProfile.Preset.allCases.first {
            $0 != .custom && $0.profile == profile
        } ?? .custom
    }

    private var presetBinding: Binding<VaultProfile.Preset> {

        Binding(
            get: { currentPreset },
            set: { profile = $0.profile }
        )
    }

    var body: some View {

        Section {

            if showsPresets {

                Picker("Modello", selection: presetBinding) {

                    ForEach(VaultProfile.Preset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
            }

            iconGrid

            colorRow

            TextField(
                "Descrizione (facoltativa)",
                text: $profile.summary,
                axis: .vertical
            )
            .lineLimit(1...3)

        } header: {
            Text("Aspetto")
        } footer: {
            Text("Icona, colore e descrizione restano visibili anche a vault bloccato e non sono cifrati: non scrivere informazioni sensibili.")
        }
    }

    private var iconGrid: some View {

        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 8),
                count: 8
            ),
            spacing: 8
        ) {

            ForEach(VaultProfile.icons, id: \.self) { icon in

                let selected = profile.icon == icon

                Image(systemName: icon)
                    .font(.body)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .foregroundStyle(selected ? profile.swiftUIColor : Color.primary)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(
                                selected
                                    ? profile.swiftUIColor.opacity(0.2)
                                    : Color(.secondarySystemBackground)
                            )
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        profile.icon = icon
                    }
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                    .accessibilityLabel(icon)
            }
        }
        .padding(.vertical, 4)
    }

    private var colorRow: some View {

        HStack(spacing: 10) {

            ForEach(VaultProfile.colorKeys, id: \.self) { key in

                let selected = profile.color == key

                Circle()
                    .fill(VaultProfile.color(for: key))
                    .frame(width: 26, height: 26)
                    .overlay {
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        profile.color = key
                    }
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                    .accessibilityLabel(key)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Properties sheet

struct VaultPropertiesView: View {

    let vaultURL: URL

    let onSaved: () -> Void

    @Environment(\.dismiss)
    private var dismiss

    @State private var profile = VaultProfile.default
    @State private var sizeText = "Calcolo in corso…"
    @State private var errorMessage: String?
    @State private var showingError = false

    var body: some View {

        NavigationStack {

            Form {

                Section {

                    HStack(spacing: 14) {

                        VaultIconBadge(profile: profile, size: 52)

                        VStack(alignment: .leading, spacing: 3) {

                            Text(vaultURL.lastPathComponent)
                                .font(.headline)

                            if !profile.summary.isEmpty {

                                Text(profile.summary)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                VaultProfileFields(profile: $profile, showsPresets: false)

                Section("Informazioni") {

                    LabeledContent("Spazio occupato", value: sizeText)

                    LabeledContent(
                        "Ultimo accesso",
                        value: lastAccessText
                    )
                }
            }
            .navigationTitle("Proprietà")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {

                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") {
                        save()
                    }
                }
            }
            .alert("Errore", isPresented: $showingError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .task {

                profile = VaultStore.shared.profile(for: vaultURL)

                let url = vaultURL

                let bytes = await Task.detached(priority: .utility) {
                    VaultStore.shared.diskUsage(of: url)
                }.value

                sizeText = ByteCountFormatter.string(
                    fromByteCount: bytes,
                    countStyle: .file
                )
            }
        }
    }

    private var lastAccessText: String {

        guard let date = VaultStore.shared.lastAccess(of: vaultURL) else {
            return "Mai"
        }

        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func save() {

        do {

            try VaultStore.shared.saveProfile(profile, for: vaultURL)

            onSaved()

            dismiss()

        } catch {

            errorMessage = error.localizedDescription
            showingError = true
        }
    }
}
