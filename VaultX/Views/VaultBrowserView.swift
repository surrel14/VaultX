import SwiftUI
import UIKit
import QuickLook

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
    let url: URL
}

struct ActivityView: UIViewControllerRepresentable {

    let url: URL

    func makeUIViewController(
        context: Context
    ) -> UIActivityViewController {

        UIActivityViewController(
            activityItems: [url],
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

    let onLock: () -> Void

    @AppStorage("browser.sortField")
    private var sortFieldRaw = SortField.name.rawValue

    @AppStorage("browser.sortAscending")
    private var sortAscending = true

    @State private var items: [VaultItem] = []
    @State private var searchText = ""
    @State private var busyMessage: String?
    @State private var biometricsEnabled = false

    @State private var showingImporter = false
    @State private var previewURL: URL?
    @State private var shareItem: VaultShareItem?
    @State private var moveCandidate: VaultItem?

    @State private var nameEditor: NameEditor?
    @State private var nameDraft = ""
    @State private var showingNameEditor = false

    @State private var deletionCandidate: VaultItem?
    @State private var showingDeleteConfirm = false

    @State private var errorMessage: String?
    @State private var showingError = false

    var body: some View {

        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                prompt: "Cerca in questa cartella"
            )
            .toolbar {
                toolbarContent
            }
            .quickLookPreview($previewURL)
            .overlay {
                busyOverlay
            }
            .background {
                presentations
            }
            .onAppear {
                loadItems()
                biometricsEnabled = VaultStore.shared
                    .isBiometricUnlockEnabled(for: session.vaultURL)
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
                requestDelete(item)
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
                    exportItem(item)
                } label: {
                    Label("Esporta", systemImage: "square.and.arrow.up")
                }
                .tint(.blue)
            }

            Button {
                moveCandidate = item
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
                exportItem(item)
            } label: {
                Label("Esporta…", systemImage: "square.and.arrow.up")
            }
        }

        Button {
            startRename(item)
        } label: {
            Label("Rinomina", systemImage: "pencil")
        }

        Button {
            moveCandidate = item
        } label: {
            Label("Sposta…", systemImage: "folder")
        }

        Button(role: .destructive) {
            requestDelete(item)
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

            Button {
                onLock()
            } label: {
                Image(systemName: "lock.fill")
            }
            .accessibilityLabel("Blocca vault")

            Menu {

                Button {
                    showingImporter = true
                } label: {
                    Label("Importa file", systemImage: "square.and.arrow.down")
                }

                Button {
                    startNewFolder()
                } label: {
                    Label("Nuova cartella", systemImage: "folder.badge.plus")
                }

                Divider()

                Picker("Ordina per", selection: $sortFieldRaw) {

                    ForEach(SortField.allCases) { field in
                        Text(field.title).tag(field.rawValue)
                    }
                }

                Picker("Ordine", selection: $sortAscending) {
                    Text("Crescente").tag(true)
                    Text("Decrescente").tag(false)
                }

                if BiometricAuth.shared.isAvailable {

                    Divider()

                    Toggle(isOn: biometricBinding) {
                        Label(
                            "Sblocca con \(BiometricAuth.shared.title)",
                            systemImage: BiometricAuth.shared.systemImage
                        )
                    }
                }

            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Altre azioni")
        }
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
                .sheet(item: $shareItem) { item in

                    ActivityView(url: item.url)
                        .presentationDetents([.medium, .large])
                }

            Color.clear
                .sheet(item: $moveCandidate) { item in

                    FolderPickerView(
                        session: session,
                        item: item
                    ) {
                        loadItems()
                    }
                }

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

                    Button("Elimina", role: .destructive) {
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

    private var visibleItems: [VaultItem] {

        let filtered = searchText.isEmpty
            ? items
            : items.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
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

    // MARK: - Load

    private func loadItems() {

        do {

            items = try session.items(in: directory)

        } catch VaultStoreError.locked {

            items = []

        } catch {

            showError(error.localizedDescription)
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

    // MARK: - Open / Export

    private func openItem(_ item: VaultItem) {

        decryptForUse(item.url) { url in
            previewURL = url
        }
    }

    private func exportItem(_ item: VaultItem) {

        decryptForUse(item.url) { url in
            shareItem = VaultShareItem(url: url)
        }
    }

    /// Decifra il file in una cartella temporanea (con il nome originale)
    /// fuori dal main thread, poi chiama `completion` con l'URL in chiaro.
    private func decryptForUse(
        _ file: URL,
        completion: @escaping @MainActor (URL) -> Void
    ) {

        guard busyMessage == nil else {
            return
        }

        busyMessage = "Decifratura in corso…"

        let session = self.session

        Task { @MainActor in

            do {

                let url = try await Task.detached(
                    priority: .userInitiated
                ) {
                    try session.decryptToTemporaryFile(file)
                }.value

                busyMessage = nil

                completion(url)

            } catch {

                busyMessage = nil

                showError(
                    "Impossibile aprire il file: "
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
            || previewURL != nil
            || shareItem != nil
            || moveCandidate != nil
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

        guard let item = deletionCandidate else {
            return "Eliminare?"
        }

        return "Eliminare «\(item.name)»?"
    }

    private var deleteMessage: String {

        guard let item = deletionCandidate else {
            return ""
        }

        if item.isFolder {
            return "La cartella e tutto il suo contenuto verranno eliminati definitivamente. L'operazione non può essere annullata."
        }

        return "Il file verrà eliminato definitivamente. L'operazione non può essere annullata."
    }

    private func requestDelete(_ item: VaultItem) {

        deletionCandidate = item
        showingDeleteConfirm = true
    }

    private func performDelete() {

        guard let item = deletionCandidate, busyMessage == nil else {
            return
        }

        busyMessage = "Eliminazione in corso…"

        let session = self.session

        Task { @MainActor in

            do {

                try await Task.detached(
                    priority: .userInitiated
                ) {
                    try session.deleteItem(item)
                }.value

            } catch {

                showError(error.localizedDescription)
            }

            busyMessage = nil

            loadItems()
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

                Text(item.name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
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
