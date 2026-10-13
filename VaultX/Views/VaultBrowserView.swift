import SwiftUI
import UIKit
import QuickLook
import PhotosUI

// MARK: - Support types

enum SortField: String, CaseIterable, Identifiable {

    case name
    case date
    case size
    case kind

    var id: String { rawValue }

    var title: String {

        switch self {
        case .name: return "Nome"
        case .date: return "Data modifica"
        case .size: return "Dimensione"
        case .kind: return "Tipo"
        }
    }
}

enum NameEditor {

    case newFolder
    case rename(VaultItem)

    var title: String {

        switch self {
        case .newFolder: return "Nuova cartella"
        case .rename: return "Rinomina"
        }
    }

    var actionTitle: String {

        switch self {
        case .newFolder: return "Crea"
        case .rename: return "Salva"
        }
    }
}

struct VaultShareItem: Identifiable {

    let id = UUID()
    let urls: [URL]
}

struct ActivityView: UIViewControllerRepresentable {

    let urls: [URL]

    func makeUIViewController(
        context: Context
    ) -> UIActivityViewController {

        UIActivityViewController(
            activityItems: urls,
            applicationActivities: nil
        )
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {
        // Nessun aggiornamento necessario.
    }
}

// MARK: - Vault Browser

/// Contenuto di una cartella del vault (la radice o una sottocartella).
struct VaultBrowserView: View {

    let session: VaultSession

    /// Cartella mostrata (su disco, dentro `data/`).
    let directory: URL

    let title: String

    /// Cambia quando il contenuto è stato modificato da fuori (es. import da "Apri con…").
    let reloadToken: UUID

    let onLock: () -> Void

    /// Permette alla scorciatoia dalla schermata principale di aprire direttamente il Cestino.
    var openTrashOnAppear: Bool = false
    var onTrashOpened: () -> Void = {}

    @AppStorage("browser.sortField")
    private var sortFieldRaw = SortField.name.rawValue

    @AppStorage("browser.sortAscending")
    private var sortAscending = true

    @State private var items: [VaultItem] = []
    @State private var searchText = ""
    @State private var busyMessage: String?
    @State private var biometricsEnabled = false

    @State private var isSelecting = false
    @State private var selection: Set<URL> = []

    @State private var showingImporter = false
    @State private var showingPhotoPicker = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showingCamera = false

    @State private var previewURL: URL?
    @State private var shareItem: VaultShareItem?
    @State private var moveRequest: MoveRequest?

    @State private var showingChangePassword = false
    @State private var showingRecovery = false
    @State private var showingLog = false
    @State private var showingTrash = false
    @State private var showingFavorites = false
    @State private var showingTagManager = false
    @State private var showingAdvancedSearch = false
    @State private var itemForTagEditing: VaultItem?
    @State private var selectedTag: String?
    @State private var secureShareItem: VaultItem?
    @State private var showingPackagePicker = false
    @State private var packageToOpen: IdentifiedURL?

    @State private var nameEditor: NameEditor?
    @State private var nameDraft = ""
    @State private var showingNameEditor = false

    @State private var deletionCandidates: [VaultItem] = []
    @State private var showingDeleteConfirm = false

    @State private var errorMessage: String?
    @State private var showingError = false

    var body: some View {

        content
            .navigationTitle(
                isSelecting
                    ? "\(selection.count) selezionati"
                    : title
            )
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                prompt: "Cerca in questa cartella"
            )
            .toolbar {
                toolbarContent
            }
            .toolbar(isSelecting ? .visible : .hidden, for: .bottomBar)
            .quickLookPreview($previewURL)
            .photosPicker(
                isPresented: $showingPhotoPicker,
                selection: $photoSelection,
                matching: .any(of: [.images, .videos])
            )
            .overlay {
                busyOverlay
            }
            .background {
                presentations
            }
            .background {
                alertPresentations
            }
            .onAppear {
                loadItems()
                biometricsEnabled = VaultStore.shared
                    .isBiometricUnlockEnabled(for: session.vaultURL)
                if openTrashOnAppear {
                    showingTrash = true
                    onTrashOpened()
                }
            }
            .onChange(of: reloadToken) { _ in
                loadItems()
            }
            .onChange(of: photoSelection) { picked in
                importPhotos(picked)
            }
            .onChange(of: previewURL) { newValue in
                if newValue == nil {
                    scheduleTemporaryCleanup()
                }
            }
            .onChange(of: shareItem?.id) { newValue in
                if newValue == nil {
                    scheduleTemporaryCleanup()
                }
            }
            .onChange(of: isExternalUIActive) { active in
                InactivityMonitor.shared.setPaused(active)
            }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {

        if items.isEmpty {

            emptyFolderView

        } else if visibleItems.isEmpty {

            VStack(spacing: 8) {

                Image(systemName: "magnifyingglass")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)

                Text("Nessun risultato")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        } else {

            itemList
        }
    }

    private var itemList: some View {

        List {

            ForEach(visibleItems) { item in
                row(for: item)
            }
        }
        .listStyle(.plain)
        .refreshable {
            loadItems()
        }
    }

    @ViewBuilder
    private func row(for item: VaultItem) -> some View {

        if isSelecting {
            selectableRow(for: item)
        } else {
            standardRow(for: item)
        }
    }

    private func selectableRow(for item: VaultItem) -> some View {

        let selected = selection.contains(item.url)

        return Button {
            toggleSelection(item)
        } label: {

            HStack(spacing: 12) {

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)

                VaultItemRow(item: item, session: session)
            }
        }
        .buttonStyle(.plain)
        .accessibilityValue(selected ? "Selezionato" : "Non selezionato")
    }

    private func standardRow(for item: VaultItem) -> some View {

        Group {

            if item.isFolder {

                NavigationLink(value: VaultFolder(url: item.url)) {
                    VaultItemRow(item: item, session: session)
                }

            } else {

                Button {
                    openItem(item)
                } label: {
                    VaultItemRow(item: item, session: session)
                }
                .buttonStyle(.plain)
            }
        }
        .contextMenu {
            contextActions(for: item)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {

            Button(role: .destructive) {
                requestDelete([item])
            } label: {
                Label("Elimina", systemImage: "trash")
            }

            Button {
                startRename(item)
            } label: {
                Label("Rinomina", systemImage: "pencil")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {

            if !item.isFolder {

                Button {
                    exportItems([item])
                } label: {
                    Label("Esporta", systemImage: "square.and.arrow.up")
                }
                .tint(.blue)
            }

            Button {
                moveRequest = MoveRequest(items: [item])
            } label: {
                Label("Sposta", systemImage: "folder")
            }
            .tint(.indigo)
        }
    }

    @ViewBuilder
    private func contextActions(for item: VaultItem) -> some View {

        if !item.isFolder {

            Button {
                openItem(item)
            } label: {
                Label("Apri", systemImage: "eye")
            }

            Button {
                exportItems([item])
            } label: {
                Label("Esporta…", systemImage: "square.and.arrow.up")
            }

            Button {
                secureShareItem = item
            } label: {
                Label("Condividi in modo sicuro…", systemImage: "shippingbox")
            }
        }

        Button {
            toggleFavorite(item)
        } label: {
            Label(item.isFavorite ? "Rimuovi dai Preferiti" : "Aggiungi ai Preferiti", systemImage: item.isFavorite ? "star.slash" : "star")
        }

        Button {
            startRename(item)
        } label: {
            Label("Rinomina", systemImage: "pencil")
        }

        Button {
            itemForTagEditing = item
        } label: {
            Label("Gestisci tag…", systemImage: "tag")
        }

        Button {
            moveRequest = MoveRequest(items: [item])
        } label: {
            Label("Sposta…", systemImage: "folder")
        }

        Button {
            beginSelection(with: item)
        } label: {
            Label("Seleziona", systemImage: "checkmark.circle")
        }

        Button(role: .destructive) {
            requestDelete([item])
        } label: {
            Label("Elimina", systemImage: "trash")
        }
    }

    private var emptyFolderView: some View {

        VStack(spacing: 16) {

            Image(systemName: "tray")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)

            Text("Cartella vuota")
                .font(.title3.weight(.semibold))

            Text("Importa dei file o crea una cartella.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {

                Button {
                    showingImporter = true
                } label: {
                    Label("Importa file", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    startNewFolder()
                } label: {
                    Label("Nuova cartella", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var busyOverlay: some View {

        if let busyMessage {

            ZStack {

                Color.black
                    .opacity(0.25)
                    .ignoresSafeArea()

                ProgressView(busyMessage)
                    .padding(20)
                    .background(
                        .regularMaterial,
                        in: RoundedRectangle(cornerRadius: 14)
                    )
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {

        ToolbarItemGroup(placement: .navigationBarTrailing) {

            if isSelecting {

                Button(allVisibleSelected ? "Nessuno" : "Tutti") {
                    toggleSelectAll()
                }

                Button("Fine") {
                    endSelection()
                }

            } else {

                Button {
                    onLock()
                } label: {
                    Image(systemName: "lock.fill")
                }
                .accessibilityLabel("Blocca vault")

                actionsMenu
            }
        }

        ToolbarItemGroup(placement: .bottomBar) {

            if isSelecting {

                Button {
                    exportItems(selectedItems.filter { !$0.isFolder })
                } label: {
                    Label("Esporta", systemImage: "square.and.arrow.up")
                }
                .disabled(!canExportSelection)

                Spacer()

                Button {
                    moveRequest = MoveRequest(items: selectedItems)
                } label: {
                    Label("Sposta", systemImage: "folder")
                }
                .disabled(selection.isEmpty)

                Spacer()

                Button(role: .destructive) {
                    requestDelete(selectedItems)
                } label: {
                    Label("Elimina", systemImage: "trash")
                }
                .disabled(selection.isEmpty)
            }
        }
    }

    private var actionsMenu: some View {

        Menu {

            Button {
                showingImporter = true
            } label: {
                Label("Importa file", systemImage: "square.and.arrow.down")
            }

            Button {
                showingPhotoPicker = true
            } label: {
                Label("Importa da Foto", systemImage: "photo.on.rectangle")
            }

            if CameraPicker.isAvailable {
                Button {
                    startCamera()
                } label: {
                    Label("Scatta foto", systemImage: "camera")
                }
            }

            Button {
                startNewFolder()
            } label: {
                Label("Nuova cartella", systemImage: "folder.badge.plus")
            }

            Button {
                showingPackagePicker = true
            } label: {
                Label("Importa pacchetto protetto", systemImage: "shippingbox")
            }

            Button {
                showingFavorites = true
            } label: {
                Label("Preferiti", systemImage: "star.fill")
            }

            if !allAvailableTags.isEmpty {
                Menu {
                    Button("Tutti i file") { selectedTag = nil }
                    Divider()
                    ForEach(allAvailableTags, id: \.self) { tag in
                        Button { selectedTag = tag } label: {
                            if selectedTag == tag {
                                Label(tag, systemImage: "checkmark")
                            } else {
                                Text(tag)
                            }
                        }
                    }
                } label: {
                    Label(selectedTag.map { "Tag: \($0)" } ?? "Filtra per tag", systemImage: "tag")
                }
            }

            Button {
                showingTagManager = true
            } label: {
                Label("Gestisci tag", systemImage: "tags")
            }

            Button {
                showingAdvancedSearch = true
            } label: {
                Label("Ricerca avanzata", systemImage: "line.3.horizontal.decrease.circle")
            }

            Button {
                showingTrash = true
            } label: {
                Label("Cestino", systemImage: "trash")
            }

            Divider()

            Button {
                beginSelection()
            } label: {
                Label("Seleziona", systemImage: "checkmark.circle")
            }
            .disabled(items.isEmpty)

            Menu {

                Picker("Ordina per", selection: $sortFieldRaw) {

                    ForEach(SortField.allCases) { field in
                        Text(field.title).tag(field.rawValue)
                    }
                }

                Picker("Ordine", selection: $sortAscending) {
                    Text("Crescente").tag(true)
                    Text("Decrescente").tag(false)
                }

            } label: {
                Label("Ordina", systemImage: "arrow.up.arrow.down")
            }

            Divider()

            Menu {

                Button {
                    showingChangePassword = true
                } label: {
                    Label("Cambia password…", systemImage: "key")
                }

                Button {
                    showingRecovery = true
                } label: {
                    Label("Chiave di recupero…", systemImage: "lifepreserver")
                }

                Button {
                    showingLog = true
                } label: {
                    Label("Registro di sicurezza…", systemImage: "list.bullet.rectangle")
                }

                if BiometricAuth.shared.isAvailable {

                    Toggle(isOn: biometricBinding) {
                        Label(
                            "Sblocca con \(BiometricAuth.shared.title)",
                            systemImage: BiometricAuth.shared.systemImage
                        )
                    }
                }

            } label: {
                Label("Sicurezza", systemImage: "lock.shield")
            }

        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Altre azioni")
    }

    // MARK: - Presentations (sheet / alert)

    /// Ogni presentazione è agganciata a un nodo separato: così non si
    /// "pestano i piedi" tra loro.
    private var presentations: some View {

        ZStack {

            Color.clear
                .sheet(isPresented: $showingImporter) {

                    VaultDocumentPicker(
                        onPick: { urls in
                            showingImporter = false
                            importFiles(urls)
                        },
                        onCancel: {
                            showingImporter = false
                        }
                    )
                    .ignoresSafeArea()
                }

            Color.clear
                .fullScreenCover(isPresented: $showingCamera) {

                    CameraPicker(
                        onCapture: { image in
                            importCapturedPhoto(image)
                        },
                        onCancel: {
                            showingCamera = false
                        }
                    )
                    .ignoresSafeArea()
                }

            Color.clear
                .sheet(item: $shareItem) { item in

                    ActivityView(urls: item.urls)
                        .presentationDetents([.medium, .large])
                }

            Color.clear
                .sheet(item: $moveRequest) { request in

                    FolderPickerView(
                        session: session,
                        items: request.items
                    ) {
                        endSelection()
                        loadItems()
                    }
                }

            Color.clear
                .sheet(isPresented: $showingChangePassword) {
                    ChangePasswordView(vaultURL: session.vaultURL)
                }

            Color.clear
                .sheet(isPresented: $showingRecovery) {
                    RecoveryKeyView(session: session)
                }

            Color.clear
                .sheet(item: $secureShareItem) { item in

                    SecureShareView(session: session, item: item) { package in

                        // Aspetta che lo sheet sia sparito prima di mostrare la condivisione.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            shareItem = VaultShareItem(urls: [package])
                        }
                    }
                }

            Color.clear
                .sheet(isPresented: $showingLog) {
                    SecurityLogView(vault: session.vaultURL.lastPathComponent)
                }

            Color.clear
                .sheet(item: $itemForTagEditing) { item in
                    TagEditorView(item: item) { tags in
                        try session.setTags(tags, for: item)
                        loadItems()
                    }
                }

            Color.clear
                .sheet(isPresented: $showingAdvancedSearch) {
                    AdvancedSearchView(session: session) { item in
                        showingAdvancedSearch = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                            openItem(item)
                        }
                    }
                }

            Color.clear
                .sheet(isPresented: $showingTagManager, onDismiss: {
                    // Ricarica la lista anche quando il gestore viene chiuso,
                    // così la UI non conserva i tag precedenti in memoria.
                    loadItems()
                    selectedTag = nil
                }) {
                    TagManagerView(session: session) {
                        // Aggiornamento immediato dopo rinomina/eliminazione,
                        // senza dover chiudere e riaprire il vault.
                        loadItems()
                        selectedTag = nil
                    }
                }

            Color.clear
                .sheet(isPresented: $showingFavorites, onDismiss: {
                    loadItems()
                }) {
                    FavoritesView(session: session, onLock: onLock)
                }

            Color.clear
                .sheet(isPresented: $showingTrash) {
                    TrashView(session: session) {
                        loadItems()
                    }
                }

            Color.clear
                .sheet(isPresented: $showingPackagePicker) {

                    VaultDocumentPicker(
                        onPick: { urls in

                            showingPackagePicker = false

                            if let url = urls.first {

                                // Aspetta che il selettore sia sparito prima di aprire il pacchetto.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    packageToOpen = IdentifiedURL(url: url)
                                }
                            }
                        },
                        onCancel: {
                            showingPackagePicker = false
                        },
                        asCopy: true,
                        allowsMultipleSelection: false
                    )
                    .ignoresSafeArea()
                }

            Color.clear
                .sheet(item: $packageToOpen) { package in

                    OpenSharePackageView(
                        url: package.url,
                        destinationName: title,
                        onSaveToVault: { fileURL in
                            try await importDecrypted(fileURL)
                        }
                    )
                }
        }
        .allowsHitTesting(false)
    }

    private var alertPresentations: some View {

        ZStack {

            Color.clear
                .alert(
                    nameEditor?.title ?? "Nome",
                    isPresented: $showingNameEditor
                ) {

                    TextField("Nome", text: $nameDraft)

                    Button("Annulla", role: .cancel) {}

                    Button(nameEditor?.actionTitle ?? "OK") {
                        commitNameEditor()
                    }
                }

            Color.clear
                .alert(
                    deleteTitle,
                    isPresented: $showingDeleteConfirm
                ) {

                    Button("Sposta nel Cestino", role: .destructive) {
                        performDelete()
                    }

                    Button("Annulla", role: .cancel) {}

                } message: {
                    Text(deleteMessage)
                }

            Color.clear
                .alert(
                    "Errore",
                    isPresented: $showingError
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(errorMessage ?? "")
                }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Sorting & search

    private var sortField: SortField {
        SortField(rawValue: sortFieldRaw) ?? .name
    }

    private var allAvailableTags: [String] {
        Array(Set(items.flatMap(\.tags))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var visibleItems: [VaultItem] {

        let filtered = items.filter { item in
            let matchesSearch = searchText.isEmpty
                || item.name.localizedCaseInsensitiveContains(searchText)
                || item.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
            let matchesTag = selectedTag.map { tag in item.tags.contains(tag) } ?? true
            return matchesSearch && matchesTag
        }

        return filtered.sorted(by: isOrderedBefore)
    }

    /// Le cartelle stanno sempre in cima; poi vale il criterio scelto.
    private func isOrderedBefore(
        _ a: VaultItem,
        _ b: VaultItem
    ) -> Bool {

        if a.isFolder != b.isFolder {
            return a.isFolder
        }

        let byName = a.name.localizedStandardCompare(b.name)

        let result: ComparisonResult

        switch sortField {

        case .name:
            result = byName

        case .date:
            result = compare(
                a.modified ?? .distantPast,
                b.modified ?? .distantPast
            )

        case .size:
            result = compare(a.size, b.size)

        case .kind:
            result = a.fileExtension.localizedStandardCompare(b.fileExtension)
        }

        if result == .orderedSame {
            return byName == .orderedAscending
        }

        return sortAscending
            ? result == .orderedAscending
            : result == .orderedDescending
    }

    private func compare<T: Comparable>(
        _ a: T,
        _ b: T
    ) -> ComparisonResult {

        if a < b {
            return .orderedAscending
        }

        if a > b {
            return .orderedDescending
        }

        return .orderedSame
    }

    private func toggleFavorite(_ item: VaultItem) {
        do {
            try session.setFavorite(!item.isFavorite, for: item)
            loadItems()
        } catch {
            showError("Impossibile aggiornare i Preferiti: \(error.localizedDescription)")
        }
    }

    // MARK: - Load

    private func loadItems() {

        do {

            items = try session.items(in: directory)

            // Toglie dalla selezione ciò che non esiste più.
            selection.formIntersection(Set(items.map(\.url)))

        } catch VaultStoreError.locked {

            items = []

        } catch {

            showError(error.localizedDescription)
        }
    }

    // MARK: - Selection

    private var selectedItems: [VaultItem] {
        items.filter { selection.contains($0.url) }
    }

    private var allVisibleSelected: Bool {

        !visibleItems.isEmpty
            && visibleItems.allSatisfy { selection.contains($0.url) }
    }

    /// Le cartelle non si esportano: l'esportazione è attiva solo se ci sono soli file.
    private var canExportSelection: Bool {

        !selection.isEmpty
            && selectedItems.allSatisfy { !$0.isFolder }
    }

    private func beginSelection(with item: VaultItem? = nil) {

        isSelecting = true
        selection = item.map { Set([$0.url]) } ?? []
    }

    private func endSelection() {

        isSelecting = false
        selection = []
    }

    private func toggleSelection(_ item: VaultItem) {

        if selection.contains(item.url) {
            selection.remove(item.url)
        } else {
            selection.insert(item.url)
        }
    }

    private func toggleSelectAll() {

        let urls = visibleItems.map(\.url)

        if allVisibleSelected {
            selection.subtract(urls)
        } else {
            selection.formUnion(urls)
        }
    }

    // MARK: - Import

    private func importFiles(_ urls: [URL]) {

        guard !urls.isEmpty, busyMessage == nil else {
            return
        }

        busyMessage = "Cifratura in corso…"

        let session = self.session
        let target = directory

        // La cifratura di file grandi è pesante: fuori dal main thread.
        Task { @MainActor in

            let failures = await Task.detached(
                priority: .userInitiated
            ) {
                session.importFiles(urls, into: target)
            }.value

            busyMessage = nil

            loadItems()

            if !failures.isEmpty {

                showError(
                    "Impossibile importare:\n"
                    + failures.joined(separator: "\n")
                )
            }
        }
    }

    private func importPhotos(_ pickerItems: [PhotosPickerItem]) {

        guard !pickerItems.isEmpty, busyMessage == nil else {
            return
        }

        busyMessage = "Caricamento da Foto…"

        let session = self.session
        let target = directory

        Task { @MainActor in

            var urls: [URL] = []
            var loadFailures = 0

            for pickerItem in pickerItems {

                if let picked = try? await pickerItem.loadTransferable(
                    type: PickedFile.self
                ) {
                    urls.append(picked.url)
                } else {
                    loadFailures += 1
                }
            }

            photoSelection = []

            busyMessage = "Cifratura in corso…"

            let failures = await Task.detached(
                priority: .userInitiated
            ) {
                session.importFiles(urls, into: target)
            }.value

            busyMessage = nil

            loadItems()

            var messages = failures

            if loadFailures > 0 {
                messages.append(
                    "\(loadFailures) elementi non sono stati caricati dalla libreria Foto."
                )
            }

            if !messages.isEmpty {

                showError(
                    "Impossibile importare:\n"
                    + messages.joined(separator: "\n")
                )
            }
        }
    }

    private func startCamera() {

        guard CameraPicker.isAvailable else {
            showError("La fotocamera non è disponibile su questo dispositivo.")
            return
        }

        // Senza questa chiave in Info.plist iOS chiude l'app all'apertura della fotocamera.
        guard CameraPicker.hasUsageDescription else {
            showError("Manca la chiave NSCameraUsageDescription in Info.plist: aggiungila per usare la fotocamera.")
            return
        }

        showingCamera = true
    }

    private func importCapturedPhoto(_ image: UIImage) {

        showingCamera = false

        do {

            let url = try ImportNaming.writeTemporaryPhoto(image)

            importFiles([url])

        } catch {

            showError(error.localizedDescription)
        }
    }

    // MARK: - Import decrypted file (protected package)

    /// Cifra con le chiavi del vault il file decifrato da un pacchetto protetto
    /// e lo aggiunge a questa cartella. Non elimina il file di partenza (serve ancora
    /// all'anteprima): la copia temporanea viene ripulita alla chiusura.
    private func importDecrypted(_ fileURL: URL) async throws {

        let currentSession = session
        let target = directory

        try await Task.detached(priority: .userInitiated) {
            _ = try currentSession.importFile(at: fileURL, into: target)
        }.value

        loadItems()
    }

    // MARK: - Open / Export

    private func openItem(_ item: VaultItem) {

        guard busyMessage == nil else {
            return
        }

        busyMessage = "Decifratura in corso…"

        let session = self.session
        let file = item.url

        Task { @MainActor in

            do {

                let url = try await Task.detached(
                    priority: .userInitiated
                ) {
                    try session.decryptToTemporaryFile(file)
                }.value

                busyMessage = nil

                previewURL = url

            } catch {

                busyMessage = nil

                showError(
                    "Impossibile aprire il file: "
                    + error.localizedDescription
                )
            }
        }
    }

    /// Decifra i file in cartelle temporanee (con il nome originale) fuori dal
    /// main thread e apre lo share sheet.
    private func exportItems(_ files: [VaultItem]) {

        guard !files.isEmpty, busyMessage == nil else {
            return
        }

        busyMessage = "Decifratura in corso…"

        let session = self.session
        let sources = files.map(\.url)

        Task { @MainActor in

            do {

                let plain = try await Task.detached(
                    priority: .userInitiated
                ) {
                    try sources.map { try session.decryptToTemporaryFile($0) }
                }.value

                busyMessage = nil

                shareItem = VaultShareItem(urls: plain)

                SecurityLog.shared.record(
                    .filesExported,
                    vault: session.vaultURL.lastPathComponent,
                    detail: "\(sources.count) file"
                )

            } catch {

                busyMessage = nil

                showError(
                    "Impossibile esportare: "
                    + error.localizedDescription
                )
            }
        }
    }

    /// Elimina le copie in chiaro poco dopo la chiusura di anteprima/condivisione
    /// (con un po' di margine: l'app di destinazione potrebbe ancora copiare il file).
    private func scheduleTemporaryCleanup() {

        DispatchQueue.main.asyncAfter(
            deadline: .now() + 20
        ) {

            if previewURL == nil,
               shareItem == nil,
               busyMessage == nil {

                VaultSession.removeTemporaryFiles()
            }
        }
    }

    /// Picker, anteprime e share sheet non passano i tocchi alla nostra
    /// finestra: durante il loro uso il timer di inattività è in pausa.
    private var isExternalUIActive: Bool {

        showingImporter
            || showingPackagePicker
            || showingPhotoPicker
            || showingCamera
            || showingTrash
            || previewURL != nil
            || shareItem != nil
            || moveRequest != nil
            || busyMessage != nil
    }

    // MARK: - New folder / Rename

    private func startNewFolder() {

        nameEditor = .newFolder
        nameDraft = ""
        showingNameEditor = true
    }

    private func startRename(_ item: VaultItem) {

        nameEditor = .rename(item)
        nameDraft = item.name
        showingNameEditor = true
    }

    private func commitNameEditor() {

        guard let editor = nameEditor else {
            return
        }

        do {

            switch editor {

            case .newFolder:
                try session.createFolder(
                    named: nameDraft,
                    in: directory
                )

            case .rename(let item):
                try session.renameItem(
                    item,
                    to: nameDraft
                )
            }

            loadItems()

        } catch {

            showError(error.localizedDescription)
        }
    }

    // MARK: - Delete

    private var deleteTitle: String {

        if deletionCandidates.count == 1, let item = deletionCandidates.first {
            return "Spostare «\(item.name)» nel Cestino?"
        }

        return "Spostare \(deletionCandidates.count) elementi nel Cestino?"
    }

    private var deleteMessage: String {

        if deletionCandidates.count == 1, let item = deletionCandidates.first {

            if item.isFolder {
                return "La cartella e tutto il suo contenuto verranno spostati nel Cestino. Potrai ripristinarli o eliminarli definitivamente dal Cestino."
            }

            return "Il file verrà spostato nel Cestino. Potrai ripristinarlo o eliminarlo definitivamente dal Cestino."
        }

        return "Gli elementi selezionati e il contenuto delle cartelle verranno spostati nel Cestino. Potrai ripristinarli o eliminarli definitivamente dal Cestino."
    }

    private func requestDelete(_ candidates: [VaultItem]) {

        guard !candidates.isEmpty else {
            return
        }

        deletionCandidates = candidates
        showingDeleteConfirm = true
    }

    private func performDelete() {

        let candidates = deletionCandidates

        guard !candidates.isEmpty, busyMessage == nil else {
            return
        }

        busyMessage = "Eliminazione in corso…"

        let session = self.session

        Task { @MainActor in

            let failures = await Task.detached(
                priority: .userInitiated
            ) {
                session.moveItemsToTrash(candidates)
            }.value

            busyMessage = nil

            SecurityLog.shared.record(
                .filesMovedToTrash,
                vault: session.vaultURL.lastPathComponent,
                detail: "\(candidates.count) elementi",
                severity: candidates.count >= 10 ? .warning : .notice
            )

            endSelection()

            loadItems()

            if !failures.isEmpty {

                showError(
                    "Impossibile spostare nel Cestino:\n"
                    + failures.joined(separator: "\n")
                )
            }
        }
    }

    // MARK: - Face ID / Touch ID

    private var biometricBinding: Binding<Bool> {

        Binding(
            get: { biometricsEnabled },
            set: { setBiometrics($0) }
        )
    }

    private func setBiometrics(_ enabled: Bool) {

        do {

            if enabled {
                try VaultStore.shared.enableBiometricUnlock(for: session)
            } else {
                VaultStore.shared.disableBiometricUnlock(for: session.vaultURL)
            }

            biometricsEnabled = enabled

        } catch {

            showError(
                "Impossibile modificare lo sblocco biometrico: "
                + error.localizedDescription
            )
        }
    }

    // MARK: - Error

    private func showError(_ message: String) {

        errorMessage = message
        showingError = true
    }
}

// MARK: - Row

struct VaultItemRow: View {

    let item: VaultItem
    let session: VaultSession

    @State private var thumbnail: UIImage?

    var body: some View {

        HStack(spacing: 14) {

            icon

            VStack(alignment: .leading, spacing: 3) {

                HStack(spacing: 5) {
                    Text(item.name)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Preferito")
                    }
                }

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if !item.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(item.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.accentColor.opacity(0.13), in: Capsule())
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .task(id: item.url) {
            await loadThumbnail()
        }
    }

    @ViewBuilder
    private var icon: some View {

        if let thumbnail {

            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                )

        } else {

            Image(systemName: Self.symbol(for: item))
                .font(.title3)
                .foregroundStyle(
                    item.isFolder ? Color.accentColor : Color.secondary
                )
                .frame(width: 44, height: 44)
                .background(
                    Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
    }

    private var subtitle: String {

        var parts: [String] = []

        if item.isFolder {
            parts.append("Cartella")
        } else {
            parts.append(
                ByteCountFormatter.string(
                    fromByteCount: item.size,
                    countStyle: .file
                )
            )
        }

        if let modified = item.modified {
            parts.append(
                modified.formatted(date: .abbreviated, time: .omitted)
            )
        }

        return parts.joined(separator: " · ")
    }

    private func loadThumbnail() async {

        guard VaultSession.supportsThumbnail(item) else {
            return
        }

        let currentSession = session
        let currentItem = item

        let image = await Task.detached(priority: .utility) {
            currentSession.thumbnail(for: currentItem)
        }.value

        thumbnail = image
    }

    static func symbol(for item: VaultItem) -> String {

        if item.isFolder {
            return "folder.fill"
        }

        switch item.fileExtension {

        case "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp":
            return "photo"

        case "mp4", "mov", "m4v", "avi", "mkv":
            return "film"

        case "mp3", "wav", "m4a", "aac", "flac":
            return "music.note"

        case "pdf":
            return "doc.richtext"

        case "zip", "rar", "7z", "tar", "gz":
            return "doc.zipper"

        case "txt", "md", "rtf", "doc", "docx", "pages":
            return "doc.text"

        case "xls", "xlsx", "numbers", "csv":
            return "tablecells"

        case "ppt", "pptx", "key":
            return "rectangle.on.rectangle"

        case "swift", "json", "xml", "html", "js", "py":
            return "chevron.left.forwardslash.chevron.right"

        default:
            return "doc"
        }
    }
}


// MARK: - Trash

/// Gestione del Cestino del vault corrente. Gli elementi restano cifrati su disco.
private struct TrashView: View {

    let session: VaultSession
    let onVaultContentChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var items: [VaultItem] = []
    private enum ConfirmationAction {
        case permanentDelete(VaultItem)
        case emptyTrash
    }

    @State private var confirmationAction: ConfirmationAction?
    @State private var showingConfirmation = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showingError = false

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "trash")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)

                        Text("Cestino vuoto")
                            .font(.title3.weight(.semibold))

                        Text("Gli elementi che elimini appariranno qui e potranno essere ripristinati.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(items) { item in
                            row(for: item)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .refreshable {
                        loadTrash()
                    }
                }
            }
            .navigationTitle("Cestino")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fine") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Svuota", role: .destructive) {
                        confirmationAction = .emptyTrash
                        showingConfirmation = true
                    }
                    .disabled(items.isEmpty || isWorking)
                }
            }
            .overlay {
                if isWorking {
                    ZStack {
                        Color.black.opacity(0.20).ignoresSafeArea()
                        ProgressView("Operazione in corso…")
                            .padding(20)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            .confirmationDialog(
                confirmationTitle,
                isPresented: $showingConfirmation,
                titleVisibility: .visible
            ) {
                switch confirmationAction {
                case .permanentDelete(let item):
                    Button("Elimina definitivamente", role: .destructive) {
                        confirmationAction = nil
                        permanentlyDelete([item])
                    }
                case .emptyTrash:
                    Button("Svuota il Cestino", role: .destructive) {
                        confirmationAction = nil
                        permanentlyDelete(items)
                    }
                case .none:
                    EmptyView()
                }

                Button("Annulla", role: .cancel) {
                    confirmationAction = nil
                }
            } message: {
                Text(confirmationMessage)
            }
            .alert("Errore", isPresented: $showingError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear {
                loadTrash()
            }
        }
    }

    @ViewBuilder
    private func row(for item: VaultItem) -> some View {
        HStack(spacing: 14) {
            Image(systemName: VaultItemRow.symbol(for: item))
                .font(.title3)
                .foregroundStyle(item.isFolder ? Color.accentColor : Color.secondary)
                .frame(width: 44, height: 44)
                .background(
                    Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(trashSubtitle(for: item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                restore(item)
            } label: {
                Label("Ripristina", systemImage: "arrow.uturn.backward")
            }

            Button(role: .destructive) {
                confirmationAction = .permanentDelete(item)
                showingConfirmation = true
            } label: {
                Label("Elimina definitivamente", systemImage: "trash.slash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                restore(item)
            } label: {
                Label("Ripristina", systemImage: "arrow.uturn.backward")
            }
            .tint(.green)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                confirmationAction = .permanentDelete(item)
                showingConfirmation = true
            } label: {
                Label("Elimina", systemImage: "trash.slash")
            }
        }
    }

    private var confirmationTitle: String {
        switch confirmationAction {
        case .permanentDelete:
            return "Eliminare definitivamente?"
        case .emptyTrash:
            return "Svuotare il Cestino?"
        case .none:
            return "Conferma"
        }
    }

    private var confirmationMessage: String {
        switch confirmationAction {
        case .permanentDelete(let item):
            return item.isFolder
                ? "La cartella «\(item.name)» e tutto il suo contenuto verranno eliminati definitivamente."
                : "Il file «\(item.name)» verrà eliminato definitivamente."
        case .emptyTrash:
            return "Tutti gli elementi nel Cestino e il contenuto delle cartelle verranno eliminati definitivamente. Non potrai recuperarli."
        case .none:
            return "Il contenuto verrà eliminato definitivamente e non potrà essere recuperato."
        }
    }

    private func trashSubtitle(for item: VaultItem) -> String {
        let typeOrSize = item.isFolder
            ? "Cartella"
            : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
        let date = item.trashedAt?.formatted(date: .abbreviated, time: .shortened)
            ?? "data non disponibile"
        return "\(typeOrSize) · Nel Cestino dal \(date)"
    }

    private func loadTrash() {
        do {
            items = try session.trashedItems()
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }

    private func restore(_ item: VaultItem) {
        guard !isWorking else { return }
        isWorking = true
        let currentSession = session

        Task { @MainActor in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try currentSession.restoreItemFromTrash(item)
                }.value

                loadTrash()
                SecurityLog.shared.record(
                    .filesRestored,
                    vault: currentSession.vaultURL.lastPathComponent,
                    detail: "1 elemento ripristinato",
                    severity: .notice
                )
                onVaultContentChanged()
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }
            isWorking = false
        }
    }

    private func permanentlyDelete(_ candidates: [VaultItem]) {
        guard !candidates.isEmpty, !isWorking else { return }
        isWorking = true
        let currentSession = session

        Task { @MainActor in
            let failures = await Task.detached(priority: .userInitiated) {
                currentSession.deleteItems(candidates)
            }.value

            let deletedCount = max(0, candidates.count - failures.count)
            if deletedCount > 0 {
                SecurityLog.shared.record(
                    .filesDeleted,
                    vault: currentSession.vaultURL.lastPathComponent,
                    detail: "\(deletedCount) elementi eliminati definitivamente",
                    severity: deletedCount >= 10 ? .warning : .notice
                )
            }

            loadTrash()
            onVaultContentChanged()
            isWorking = false

            if !failures.isEmpty {
                errorMessage = "Impossibile eliminare definitivamente:\n"
                    + failures.joined(separator: "\n")
                showingError = true
            }
        }
    }
}


// MARK: - Tag editor

private struct TagEditorView: View {

    let item: VaultItem
    let onSave: ([String]) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var errorMessage: String?

    init(item: VaultItem, onSave: @escaping ([String]) throws -> Void) {
        self.item = item
        self.onSave = onSave
        _draft = State(initialValue: item.tags.joined(separator: ", "))
    }

    private var parsedTags: [String] {
        draft.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Lavoro, Importante, Personale", text: $draft, axis: .vertical)
                        .lineLimit(2...4)
                        .textInputAutocapitalization(.never)
                    Text("Separa i tag con una virgola. Massimo 20 tag, 32 caratteri ciascuno.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Tag per \(item.name)")
                }

                if !parsedTags.isEmpty {
                    Section("Anteprima") {
                        TagFlowLayout(spacing: 8) {
                            ForEach(Array(parsedTags.prefix(20).enumerated()), id: \.offset) { _, tag in
                                Text(String(tag.prefix(32)))
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 6)
                                    .background(Color.accentColor.opacity(0.13), in: Capsule())
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Gestisci tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") {
                        do {
                            try onSave(Array(parsedTags.prefix(20)))
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            }
        }
    }
}


// MARK: - Compact wrapping layout for tag chips

/// Keeps tag chips close together and wraps to the next line only when needed.
private struct TagFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let availableWidth = proposal.width ?? 320
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > availableWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            lineHeight = max(lineHeight, size.height)
            x += size.width + (x == 0 ? 0 : spacing)
        }
        return CGSize(width: availableWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}


// MARK: - Centralized tag manager
private struct FavoritesView: View {
    let session: VaultSession
    let onLock: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var items: [VaultItem] = []
    @State private var errorMessage: String?
    @State private var previewURL: URL?
    @State private var isOpeningFile = false

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "star")
                            .font(.system(size: 42))
                            .foregroundStyle(.secondary)
                        Text("Nessun preferito")
                            .font(.headline)
                        Text("Apri il menu di un file o di una cartella e scegli Aggiungi ai Preferiti.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(items) { item in
                            if item.isFolder {
                                NavigationLink(value: VaultFolder(url: item.url)) {
                                    VaultItemRow(item: item, session: session)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) { removeFavorite(item) } label: {
                                        Label("Rimuovi", systemImage: "star.slash")
                                    }
                                }
                            } else {
                                Button { openFavoriteFile(item) } label: {
                                    HStack {
                                        VaultItemRow(item: item, session: session)
                                        Spacer(minLength: 4)
                                        Image(systemName: "arrow.up.right.square")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) { removeFavorite(item) } label: {
                                        Label("Rimuovi", systemImage: "star.slash")
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Preferiti")
            .navigationBarTitleDisplayMode(.inline)
            .quickLookPreview($previewURL)
            .overlay {
                if isOpeningFile {
                    ProgressView("Apertura file…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .onChange(of: previewURL) { newValue in
                InactivityMonitor.shared.setPaused(newValue != nil || isOpeningFile)
                if newValue == nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                        if previewURL == nil && !isOpeningFile {
                            VaultSession.removeTemporaryFiles()
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Chiudi") { dismiss() }
                }
            }
            .navigationDestination(for: VaultFolder.self) { folder in
                VaultBrowserView(
                    session: session,
                    directory: folder.url,
                    title: session.displayName(for: folder.url),
                    reloadToken: UUID(),
                    onLock: onLock
                )
            }
            .alert("Errore", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear(perform: reload)
        }
    }

    private func reload() {
        do { items = try session.favoriteItems() }
        catch { errorMessage = error.localizedDescription }
    }

    /// Apre il file direttamente da questa schermata, senza chiudere e ricreare
    /// il foglio Preferiti: Quick Look viene presentato sopra la lista esistente.
    private func openFavoriteFile(_ item: VaultItem) {
        guard !isOpeningFile else { return }
        isOpeningFile = true
        InactivityMonitor.shared.setPaused(true)
        let currentSession = session
        let fileURL = item.url

        Task { @MainActor in
            do {
                let decryptedURL = try await Task.detached(priority: .userInitiated) {
                    try currentSession.decryptToTemporaryFile(fileURL)
                }.value
                isOpeningFile = false
                previewURL = decryptedURL
            } catch {
                isOpeningFile = false
                InactivityMonitor.shared.setPaused(false)
                errorMessage = "Impossibile aprire il file: " + error.localizedDescription
            }
        }
    }

    private func removeFavorite(_ item: VaultItem) {
        do {
            try session.setFavorite(false, for: item)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct TagManagerView: View {
    let session: VaultSession
    let onTagsChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var summaries: [VaultSession.TagSummary] = []
    @State private var selectedTag: VaultSession.TagSummary?
    @State private var renameTarget: VaultSession.TagSummary?
    @State private var renameDraft = ""
    @State private var deleteTarget: VaultSession.TagSummary?
    @State private var errorMessage: String?
    @State private var showingError = false

    var body: some View {
        NavigationStack {
            Group {
                if summaries.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tag").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Nessun tag").font(.headline)
                        Text("Aggiungi tag ai file dal loro menu contestuale.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.padding()
                } else {
                    List {
                        ForEach(summaries) { summary in
                            Button { selectedTag = summary } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "tag.fill").foregroundStyle(Color.accentColor)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(summary.name).foregroundStyle(.primary)
                                        Text("\(summary.fileCount) file").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Menu {
                                        Button { renameTarget = summary; renameDraft = summary.name } label: { Label("Rinomina", systemImage: "pencil") }
                                        Button(role: .destructive) { deleteTarget = summary } label: { Label("Elimina tag", systemImage: "trash") }
                                    } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                                    .buttonStyle(.borderless)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Gestisci tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } }
            }
            .sheet(item: $selectedTag) { summary in
                NavigationStack {
                    List(summary.filePaths, id: \.self) { path in
                        Label(path, systemImage: "doc")
                            .font(.body)
                            .textSelection(.enabled)
                    }
                    .navigationTitle(summary.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fine") { selectedTag = nil } } }
                }
            }
            .alert("Rinomina tag", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
                TextField("Nome del tag", text: $renameDraft)
                Button("Annulla", role: .cancel) { renameTarget = nil }
                Button("Salva") { renameTag() }
            } message: { Text("Il nuovo nome verrà applicato a tutti i file associati.") }
            .confirmationDialog("Eliminare il tag «\(deleteTarget?.name ?? "")»?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }), titleVisibility: .visible) {
                Button("Elimina tag da tutti i file", role: .destructive) { deleteTag() }
                Button("Annulla", role: .cancel) { deleteTarget = nil }
            } message: { Text("I file non verranno eliminati.") }
            .alert("Errore", isPresented: $showingError) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "Operazione non riuscita.") }
            .onAppear(perform: reload)
        }
    }

    private func reload() {
        do { summaries = try session.tagSummaries() }
        catch { errorMessage = error.localizedDescription; showingError = true }
    }

    private func renameTag() {
        guard let target = renameTarget else { return }
        do {
            try session.renameTag(target.name, to: renameDraft)
            renameTarget = nil
            reload()
            onTagsChanged()
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }

    private func deleteTag() {
        guard let target = deleteTarget else { return }
        do {
            try session.deleteTag(target.name)
            deleteTarget = nil
            reload()
            onTagsChanged()
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }
}


// MARK: - Advanced search
private struct AdvancedSearchView: View {
    let session: VaultSession
    let onOpen: (VaultItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedTag = "Tutti i tag"
    @State private var fileType = "Tutti"
    @State private var folderPath = ""
    @State private var useDateRange = false
    @State private var modifiedAfter = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var modifiedBefore = Date()
    @State private var minimumSize = ""
    @State private var maximumSize = ""
    @State private var tags: [String] = []
    @State private var results: [VaultSession.SearchResult] = []
    @State private var hasSearched = false
    @State private var errorMessage: String?
    @State private var showingError = false
    @State private var searching = false

    private let fileTypes = ["Tutti", "PDF", "Immagini", "Video", "Audio", "Documenti", "Archivi", "Senza estensione", "Altri tipi"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Contenuto") {
                    TextField("Nome, percorso o tag", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Tag", selection: $selectedTag) {
                        Text("Tutti i tag").tag("Tutti i tag")
                        ForEach(tags, id: \.self) { tag in Text(tag).tag(tag) }
                    }
                    Picker("Tipo di file", selection: $fileType) {
                        ForEach(fileTypes, id: \.self) { type in Text(type).tag(type) }
                    }
                    TextField("Cartella o percorso contiene…", text: $folderPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Data di modifica") {
                    Toggle("Filtra per data", isOn: $useDateRange)
                    if useDateRange {
                        DatePicker("Da", selection: $modifiedAfter, displayedComponents: .date)
                        DatePicker("A", selection: $modifiedBefore, in: modifiedAfter..., displayedComponents: .date)
                    }
                }

                Section("Dimensione (MB)") {
                    TextField("Minima", text: $minimumSize)
                        .keyboardType(.decimalPad)
                    TextField("Massima", text: $maximumSize)
                        .keyboardType(.decimalPad)
                    Text("Lascia vuoto un campo per non applicare quel limite.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        performSearch()
                    } label: {
                        HStack {
                            Spacer()
                            if searching { ProgressView().padding(.trailing, 6) }
                            Label("Cerca in tutto il vault", systemImage: "magnifyingglass")
                            Spacer()
                        }
                    }
                    .disabled(searching)

                    if hasSearched {
                        HStack {
                            Text("Risultati")
                            Spacer()
                            Text("\(results.count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }

                if hasSearched {
                    Section("File trovati") {
                        if results.isEmpty {
                            ContentUnavailableSearchFallback()
                        } else {
                            ForEach(results) { result in
                                Button { onOpen(result.item) } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack(spacing: 8) {
                                            Image(systemName: icon(for: result.item.fileExtension))
                                                .foregroundStyle(Color.accentColor)
                                            Text(result.item.name)
                                                .font(.body.weight(.medium))
                                                .foregroundStyle(.primary)
                                                .lineLimit(2)
                                            Spacer(minLength: 4)
                                            Image(systemName: "arrow.up.right.square")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(result.path)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                        HStack(spacing: 8) {
                                            Text(ByteCountFormatter.string(fromByteCount: result.item.size, countStyle: .file))
                                            if let date = result.item.modified {
                                                Text("·")
                                                Text(date.formatted(date: .abbreviated, time: .omitted))
                                            }
                                        }
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        if !result.item.tags.isEmpty {
                                            Text(result.item.tags.joined(separator: " · "))
                                                .font(.caption2)
                                                .foregroundStyle(Color.accentColor)
                                                .lineLimit(1)
                                        }
                                    }
                                    .padding(.vertical, 3)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Ricerca avanzata")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Chiudi") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Azzera") { resetFilters() }
                }
            }
            .alert("Ricerca non riuscita", isPresented: $showingError) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "Si è verificato un errore.") }
            .onAppear(perform: loadTags)
        }
    }

    private func loadTags() {
        do { tags = try session.tagSummaries().map(\.name) }
        catch { errorMessage = error.localizedDescription; showingError = true }
    }

    private func performSearch() {
        // Chiude anche la tastiera numerica (.decimalPad), che non espone un tasto Fine.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        searching = true
        do {
            let minBytes = try parseSize(minimumSize, label: "dimensione minima")
            let maxBytes = try parseSize(maximumSize, label: "dimensione massima")
            if let minBytes, let maxBytes, minBytes > maxBytes {
                throw SearchValidationError.invalidRange
            }
            results = try session.searchFiles(
                query: query,
                tag: selectedTag == "Tutti i tag" ? nil : selectedTag,
                fileType: fileType,
                modifiedAfter: useDateRange ? modifiedAfter : nil,
                modifiedBefore: useDateRange ? modifiedBefore : nil,
                minimumSizeBytes: minBytes,
                maximumSizeBytes: maxBytes,
                folderPath: folderPath
            )
            hasSearched = true
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
        searching = false
    }

    private func parseSize(_ raw: String, label: String) throws -> Int64? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard !value.isEmpty else { return nil }
        guard let number = Double(value), number >= 0, number.isFinite, number <= Double(Int64.max) / 1_048_576 else {
            throw SearchValidationError.invalidSize(label)
        }
        return Int64(number * 1_048_576)
    }

    private func resetFilters() {
        query = ""
        selectedTag = "Tutti i tag"
        fileType = "Tutti"
        folderPath = ""
        useDateRange = false
        modifiedAfter = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
        modifiedBefore = Date()
        minimumSize = ""
        maximumSize = ""
        results = []
        hasSearched = false
    }

    private func icon(for ext: String) -> String {
        switch ext.lowercased() {
        case "pdf": return "doc.richtext"
        case "jpg", "jpeg", "png", "heic", "gif", "webp": return "photo"
        case "mov", "mp4", "m4v", "avi", "mkv": return "video"
        case "mp3", "m4a", "wav", "flac", "aac": return "waveform"
        case "zip", "7z", "rar", "tar", "gz": return "archivebox"
        default: return "doc"
        }
    }
}

private struct ContentUnavailableSearchFallback: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.secondary)
            Text("Nessun file trovato").font(.headline)
            Text("Prova a modificare o rimuovere alcuni filtri.").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }
}

private enum SearchValidationError: LocalizedError {
    case invalidRange
    case invalidSize(String)
    var errorDescription: String? {
        switch self {
        case .invalidRange: return "La dimensione minima non può superare quella massima."
        case .invalidSize(let label): return "Inserisci un valore valido per la \(label), in MB."
        }
    }
}
