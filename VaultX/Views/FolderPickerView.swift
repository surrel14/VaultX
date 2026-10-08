import SwiftUI

/// Richiesta di spostamento (Identifiable per `.sheet(item:)`).
struct MoveRequest: Identifiable {

    let id = UUID()
    let items: [VaultItem]
}

/// Sheet per scegliere la cartella di destinazione di uno o più elementi.
struct FolderPickerView: View {

    let session: VaultSession

    let items: [VaultItem]

    let onMoved: () -> Void

    @Environment(\.dismiss)
    private var dismiss

    @State private var errorMessage: String?
    @State private var showingError = false

    var body: some View {

        NavigationStack {

            FolderPickerLevel(
                session: session,
                items: items,
                directory: session.rootDirectory,
                title: session.manifest.name,
                onChoose: { folder in
                    move(to: folder)
                },
                onCancel: {
                    dismiss()
                }
            )
        }
        .alert(
            "Impossibile spostare",
            isPresented: $showingError
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func move(to folder: URL) {

        let failures = session.moveItems(items, to: folder)

        onMoved()

        if failures.isEmpty {

            dismiss()

        } else {

            errorMessage = failures.joined(separator: "\n")
            showingError = true
        }
    }
}

private struct FolderPickerLevel: View {

    let session: VaultSession
    let items: [VaultItem]
    let directory: URL
    let title: String
    let onChoose: (URL) -> Void
    let onCancel: () -> Void

    @State private var folders: [VaultItem] = []

    var body: some View {

        List {

            if folders.isEmpty {

                Text("Nessuna sottocartella")
                    .foregroundStyle(.secondary)
            }

            ForEach(folders) { folder in

                NavigationLink {

                    FolderPickerLevel(
                        session: session,
                        items: items,
                        directory: folder.url,
                        title: folder.name,
                        onChoose: onChoose,
                        onCancel: onCancel
                    )

                } label: {

                    Label(
                        folder.name,
                        systemImage: "folder.fill"
                    )
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {

            ToolbarItem(placement: .cancellationAction) {
                Button("Annulla") {
                    onCancel()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Sposta qui") {
                    onChoose(directory)
                }
                .disabled(session.movableCount(items, to: directory) == 0)
            }
        }
        .onAppear {
            loadFolders()
        }
    }

    private func loadFolders() {

        let all = (try? session.items(in: directory)) ?? []

        // Una cartella che stiamo spostando non può essere una destinazione.
        let movingFolders = Set(
            items
                .filter { $0.isFolder }
                .map { $0.url.standardizedFileURL.path }
        )

        folders = all
            .filter { entry in
                entry.isFolder
                    && !movingFolders.contains(entry.url.standardizedFileURL.path)
            }
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }
}
