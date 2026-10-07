import SwiftUI

/// Sheet per scegliere la cartella di destinazione di uno spostamento.
struct FolderPickerView: View {

    let session: VaultSession

    let item: VaultItem

    let onMoved: () -> Void

    @Environment(\.dismiss)
    private var dismiss

    @State private var errorMessage: String?
    @State private var showingError = false

    var body: some View {

        NavigationStack {

            FolderPickerLevel(
                session: session,
                item: item,
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

        do {

            try session.moveItem(item, to: folder)

            onMoved()

            dismiss()

        } catch {

            errorMessage = error.localizedDescription
            showingError = true
        }
    }
}

private struct FolderPickerLevel: View {

    let session: VaultSession
    let item: VaultItem
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
                        item: item,
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
                .disabled(!session.canMove(item, to: directory))
            }
        }
        .onAppear {
            loadFolders()
        }
    }

    private func loadFolders() {

        let all = (try? session.items(in: directory)) ?? []

        let movingPath = item.url.standardizedFileURL.path

        folders = all
            .filter { entry in
                entry.isFolder
                    && !(item.isFolder
                         && entry.url.standardizedFileURL.path == movingPath)
            }
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }
}
