import SwiftUI
import UIKit

// MARK: - Helpers

/// Wrapper Identifiable per presentare uno sheet con `.sheet(item:)`.
struct VaultSelection: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Valore di navigazione per le sottocartelle di un vault aperto.
struct VaultFolder: Hashable {
    let url: URL
}

struct IdentifiedURL: Identifiable {
    let id = UUID()
    let url: URL
}

struct LogTarget: Identifiable {
    let id = UUID()
    let vault: String?
}

/// Avanzamento di un'operazione lunga (aggiornato da un thread in background).
final class OperationProgress: ObservableObject, @unchecked Sendable {

    @Published private(set) var done: Int64 = 0
    @Published private(set) var total: Int64 = 0

    var fraction: Double? {
        total > 0 ? min(1, Double(done) / Double(total)) : nil
    }

    func update(done: Int64, total: Int64) {

        DispatchQueue.main.async {
            self.done = done
            self.total = total
        }
    }

    func reset() {

        DispatchQueue.main.async {
            self.done = 0
            self.total = 0
        }
    }
}

// MARK: - ContentView

struct ContentView: View {

    @Environment(\.scenePhase)
    private var scenePhase

    @AppStorage(AppSettings.backgroundLockKey)
    private var backgroundLockSeconds = AppSettings.defaultBackgroundLockSeconds

    @AppStorage(AppSettings.inactivityLockKey)
    private var inactivityLockSeconds = AppSettings.defaultInactivityLockSeconds

    // Vault
    @State private var vaults: [URL] = []
    @State private var vaultInfo: [URL: VaultListInfo] = [:]
    @State private var biometricVaults: Set<URL> = []

    @State private var activeSession: VaultSession?
    @State private var path: [VaultFolder] = []

    // Sheet
    @State private var unlockTarget: VaultSelection?
    @State private var propertiesTarget: VaultSelection?
    @State private var logTarget: LogTarget?
    @State private var showingCreateVault = false
    @State private var showingSettings = false
    @State private var showingVaultImporter = false
    @State private var showingPackageOpener = false
    @State private var sharePackageToOpen: IdentifiedURL?
    @State private var exportShareItem: VaultShareItem?

    // Conferme e messaggi
    @State private var vaultPendingDeletion: URL?
    @State private var showingVaultDeleteConfirm = false
    @State private var errorMessage: String?
    @State private var showingError = false
    @State private var infoMessage: String?
    @State private var showingInfo = false

    // Operazioni lunghe
    @State private var vaultBusy: String?
    @StateObject private var operationProgress = OperationProgress()

    // Blocco automatico
    @State private var backgroundedAt: Date?
    @State private var isScreenCaptured = false

    // File in arrivo da altre app ("Apri con VaultX")
    @State private var reloadToken = UUID()
    @State private var pendingIncoming: [URL] = []
    @State private var showingIncomingConfirm = false
    @State private var isImportingIncoming = false
    @State private var incomingVaultPackage: IdentifiedURL?
    @State private var incomingVaultName = ""
    @State private var showingIncomingVault = false

    var body: some View {

        NavigationStack(path: $path) {

            root
                .navigationDestination(for: VaultFolder.self) { folder in

                    if let session = activeSession {

                        VaultBrowserView(
                            session: session,
                            directory: folder.url,
                            title: session.displayName(for: folder.url),
                            reloadToken: reloadToken,
                            onLock: { lockVault() }
                        )
                    }
                }
        }
        .overlay {
            privacyCover
        }
        .overlay {
            busyOverlay
        }
        .background {
            sheetPresentations
        }
        .background {
            alertPresentations
        }
        .onAppear {
            loadVaults()
            isScreenCaptured = Self.currentScreenIsCaptured()
        }
        .onOpenURL { url in
            handleIncoming(url)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIScreen.capturedDidChangeNotification
            )
        ) { _ in
            isScreenCaptured = Self.currentScreenIsCaptured()
        }
        .onChange(of: scenePhase) { phase in
            handleScenePhase(phase)
        }
        .onChange(of: exportShareItem?.id) { newValue in
            if newValue == nil {
                scheduleExportCleanup()
            }
        }
        .onChange(of: activeSession?.vaultURL) { url in

            if url != nil {

                startInactivityMonitor()

                // Aspetta che lo sheet di sblocco sia sparito prima di mostrare l'alert.
                if !pendingIncoming.isEmpty {

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {

                        if activeSession != nil, !pendingIncoming.isEmpty {
                            showingIncomingConfirm = true
                        }
                    }
                }

            } else {

                InactivityMonitor.shared.stop()
            }
        }
    }

    // MARK: - Root

    @ViewBuilder
    private var root: some View {

        if let session = activeSession {

            VaultBrowserView(
                session: session,
                directory: session.rootDirectory,
                title: session.displayName(for: session.rootDirectory),
                reloadToken: reloadToken,
                onLock: { lockVault() }
            )

        } else {

            vaultListScreen
        }
    }

    private var vaultListScreen: some View {

        Group {

            if vaults.isEmpty {
                emptyState
            } else {
                vaultList
            }
        }
        .navigationTitle("VaultX")
        .safeAreaInset(edge: .top) {
            pendingBanner
        }
        .toolbar {

            ToolbarItem(placement: .navigationBarLeading) {

                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Impostazioni")
            }

            ToolbarItem(placement: .navigationBarTrailing) {

                Menu {

                    Button {
                        showingCreateVault = true
                    } label: {
                        Label("Nuovo vault", systemImage: "plus")
                    }

                    Button {
                        showingVaultImporter = true
                    } label: {
                        Label("Importa vault…", systemImage: "square.and.arrow.down")
                    }

                    Divider()

                    Button {
                        showingPackageOpener = true
                    } label: {
                        Label("Apri pacchetto protetto…", systemImage: "shippingbox")
                    }

                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Aggiungi")
            }
        }
    }

    private var emptyState: some View {

        VStack(spacing: 18) {

            Image(systemName: "lock.shield")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text("Nessun vault")
                .font(.title2.weight(.semibold))

            Text("Crea un vault protetto da password per cifrare i tuoi file, oppure importane uno esportato da un altro dispositivo.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(spacing: 10) {

                Button {
                    showingCreateVault = true
                } label: {
                    Label("Crea vault", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    showingVaultImporter = true
                } label: {
                    Label("Importa vault", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var vaultList: some View {

        List {

            ForEach(vaults, id: \.self) { vault in

                Button {
                    unlockTarget = VaultSelection(url: vault)
                } label: {
                    VaultRow(
                        url: vault,
                        info: vaultInfo[vault] ?? VaultListInfo(),
                        hasBiometrics: biometricVaults.contains(vault)
                    )
                }
                .buttonStyle(.plain)
                .contextMenu {

                    Button {
                        propertiesTarget = VaultSelection(url: vault)
                    } label: {
                        Label("Proprietà…", systemImage: "info.circle")
                    }

                    Button {
                        exportVault(vault)
                    } label: {
                        Label("Esporta…", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        duplicateVault(vault)
                    } label: {
                        Label("Duplica", systemImage: "doc.on.doc")
                    }

                    Button {
                        logTarget = LogTarget(vault: vault.lastPathComponent)
                    } label: {
                        Label("Registro di sicurezza", systemImage: "list.bullet.rectangle")
                    }

                    Divider()

                    Button(role: .destructive) {
                        vaultPendingDeletion = vault
                        showingVaultDeleteConfirm = true
                    } label: {
                        Label("Elimina", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {

                    Button(role: .destructive) {
                        vaultPendingDeletion = vault
                        showingVaultDeleteConfirm = true
                    } label: {
                        Label("Elimina", systemImage: "trash")
                    }

                    Button {
                        exportVault(vault)
                    } label: {
                        Label("Esporta", systemImage: "square.and.arrow.up")
                    }
                    .tint(.blue)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {

                    Button {
                        propertiesTarget = VaultSelection(url: vault)
                    } label: {
                        Label("Proprietà", systemImage: "info.circle")
                    }
                    .tint(.indigo)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            loadVaults()
        }
    }

    // MARK: - Presentations

    private var sheetPresentations: some View {

        ZStack {

            Color.clear
                .sheet(isPresented: $showingCreateVault) {

                    CreateVaultView {
                        loadVaults()
                    }
                }

            Color.clear
                .sheet(isPresented: $showingSettings) {
                    SettingsView()
                }

            Color.clear
                .sheet(item: $unlockTarget) { target in

                    NavigationStack {

                        UnlockVaultView(vaultURL: target.url) { session in
                            activeSession = session
                            unlockTarget = nil
                        }
                    }
                }

            Color.clear
                .sheet(item: $propertiesTarget) { target in

                    VaultPropertiesView(vaultURL: target.url) {
                        loadVaults()
                    }
                }

            Color.clear
                .sheet(item: $logTarget) { target in
                    SecurityLogView(vault: target.vault)
                }

            Color.clear
                .sheet(isPresented: $showingVaultImporter) {

                    VaultDocumentPicker(
                        onPick: { urls in

                            showingVaultImporter = false

                            if let url = urls.first {
                                importVault(from: url)
                            }
                        },
                        onCancel: {
                            showingVaultImporter = false
                        },
                        asCopy: false,
                        allowsMultipleSelection: false
                    )
                    .ignoresSafeArea()
                }

            Color.clear
                .sheet(isPresented: $showingPackageOpener) {

                    VaultDocumentPicker(
                        onPick: { urls in

                            showingPackageOpener = false

                            if let url = urls.first {

                                // Aspetta che il selettore sia sparito prima di aprire il pacchetto.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    sharePackageToOpen = IdentifiedURL(url: url)
                                }
                            }
                        },
                        onCancel: {
                            showingPackageOpener = false
                        },
                        asCopy: false,
                        allowsMultipleSelection: false
                    )
                    .ignoresSafeArea()
                }

            Color.clear
                .sheet(item: $sharePackageToOpen) { package in
                    OpenSharePackageView(url: package.url)
                }

            Color.clear
                .sheet(item: $exportShareItem) { item in

                    ActivityView(urls: item.urls)
                        .presentationDetents([.medium, .large])
                }
        }
        .allowsHitTesting(false)
    }

    private var alertPresentations: some View {

        ZStack {

            Color.clear
                .alert(
                    "Eliminare il vault?",
                    isPresented: $showingVaultDeleteConfirm
                ) {

                    Button("Elimina", role: .destructive) {
                        deletePendingVault()
                    }

                    Button("Annulla", role: .cancel) {}

                } message: {

                    Text("«\(vaultPendingDeletion?.lastPathComponent ?? "")» e tutti i file cifrati al suo interno verranno eliminati definitivamente. L'operazione non può essere annullata.")
                }

            Color.clear
                .alert(
                    incomingTitle,
                    isPresented: $showingIncomingConfirm
                ) {

                    Button("Importa") {
                        importIncoming()
                    }

                    Button("Annulla", role: .cancel) {
                        discardIncoming()
                    }

                } message: {

                    Text("I file verranno cifrati nella cartella «\(incomingDestinationName)».")
                }

            Color.clear
                .alert(
                    "Importare il vault «\(incomingVaultName)»?",
                    isPresented: $showingIncomingVault
                ) {

                    Button("Importa") {

                        if let package = incomingVaultPackage {
                            importVault(from: package.url)
                        }
                    }

                    Button("Annulla", role: .cancel) {
                        discardIncomingVaultPackage()
                    }

                } message: {

                    Text("Verrà creato un nuovo vault: non sostituisce quelli esistenti. Si apre con la password del vault originale.")
                }

            Color.clear
                .alert(
                    "Fatto",
                    isPresented: $showingInfo
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(infoMessage ?? "")
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

    /// Copre l'interfaccia quando l'app non è attiva (app switcher,
    /// centro di controllo...) o durante una registrazione dello schermo.
    @ViewBuilder
    private var privacyCover: some View {

        if activeSession != nil, scenePhase != .active || isScreenCaptured {

            ZStack {

                Color(.systemBackground)
                    .ignoresSafeArea()

                VStack(spacing: 12) {

                    Image(systemName: "lock.fill")
                        .font(.system(size: 44))

                    Text(
                        isScreenCaptured && scenePhase == .active
                            ? "Registrazione schermo attiva"
                            : "Vault protetto"
                    )
                    .font(.headline)
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var busyOverlay: some View {

        if let message = vaultBusy ?? (isImportingIncoming ? "Cifratura in corso…" : nil) {

            ZStack {

                Color.black
                    .opacity(0.25)
                    .ignoresSafeArea()

                VStack(spacing: 12) {

                    if let fraction = operationProgress.fraction, vaultBusy != nil {

                        ProgressView(value: fraction)
                            .frame(width: 200)

                        Text(message)
                            .font(.subheadline)

                        Text("\(Int(fraction * 100))%")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                    } else {

                        ProgressView(message)
                    }
                }
                .padding(20)
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: 14)
                )
            }
        }
    }

    // MARK: - Vaults

    private func loadVaults() {

        do {

            let list = try VaultStore.shared.vaults()

            vaults = list

            var infos: [URL: VaultListInfo] = [:]

            for url in list {

                var info = VaultStore.shared.quickInfo(for: url)

                // Si tiene la dimensione già calcolata finché non arriva quella nuova.
                info.sizeBytes = vaultInfo[url]?.sizeBytes

                infos[url] = info
            }

            vaultInfo = infos

            biometricVaults = Set(
                list.filter {
                    VaultStore.shared.isBiometricUnlockEnabled(for: $0)
                }
            )

            loadSizes(for: list)

        } catch {

            errorMessage = error.localizedDescription
            showingError = true
        }
    }

    /// La dimensione richiede di scorrere tutti i file: si calcola in background.
    private func loadSizes(for list: [URL]) {

        Task { @MainActor in

            let sizes = await Task.detached(priority: .utility) { () -> [URL: Int64] in

                var result: [URL: Int64] = [:]

                for url in list {
                    result[url] = VaultStore.shared.diskUsage(of: url)
                }

                return result

            }.value

            for (url, size) in sizes {
                vaultInfo[url]?.sizeBytes = size
            }
        }
    }

    private func deletePendingVault() {

        guard let url = vaultPendingDeletion else {
            return
        }

        Task { @MainActor in

            do {

                try await Task.detached(
                    priority: .userInitiated
                ) {
                    try VaultStore.shared.deleteVault(at: url)
                }.value

            } catch {

                errorMessage = error.localizedDescription
                showingError = true
            }

            loadVaults()
        }
    }

    // MARK: - Export / import / duplicate

    private func exportVault(_ url: URL) {

        guard vaultBusy == nil else {
            return
        }

        vaultBusy = "Esportazione in corso…"
        operationProgress.reset()

        let tracker = operationProgress

        Task { @MainActor in

            do {

                let package = try await Task.detached(
                    priority: .userInitiated
                ) { () -> URL in

                    let folder = FileManager.default.temporaryDirectory
                        .appendingPathComponent("VaultXExport", isDirectory: true)
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)

                    try FileManager.default.createDirectory(
                        at: folder,
                        withIntermediateDirectories: true
                    )

                    let destination = folder.appendingPathComponent(
                        "\(url.lastPathComponent).\(VaultPackage.fileExtension)"
                    )

                    try VaultStore.shared.exportVault(at: url, to: destination) { done, total in
                        tracker.update(done: done, total: total)
                    }

                    return destination

                }.value

                vaultBusy = nil

                exportShareItem = VaultShareItem(urls: [package])

            } catch {

                vaultBusy = nil

                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }

    /// I pacchetti esportati sono cifrati, ma non hanno motivo di restare in tmp.
    private func scheduleExportCleanup() {

        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {

            if exportShareItem == nil, vaultBusy == nil {
                VaultSession.removeTemporaryFiles()
            }
        }
    }

    private func importVault(from url: URL) {

        guard vaultBusy == nil else {
            return
        }

        vaultBusy = "Importazione in corso…"
        operationProgress.reset()

        let tracker = operationProgress

        Task { @MainActor in

            do {

                let imported = try await Task.detached(
                    priority: .userInitiated
                ) {
                    try VaultStore.shared.importVaultPackage(from: url) { done, total in
                        tracker.update(done: done, total: total)
                    }
                }.value

                vaultBusy = nil

                loadVaults()

                infoMessage = "Vault «\(imported.lastPathComponent)» importato. Si apre con la password del vault originale."
                showingInfo = true

            } catch {

                vaultBusy = nil

                errorMessage = error.localizedDescription
                showingError = true
            }

            // Se il pacchetto era una copia ricevuta da "Apri con…" la eliminiamo.
            if VaultSession.isDisposableCopy(url) {
                try? FileManager.default.removeItem(at: url)
            }

            incomingVaultPackage = nil
        }
    }

    private func duplicateVault(_ url: URL) {

        guard vaultBusy == nil else {
            return
        }

        vaultBusy = "Duplicazione in corso…"
        operationProgress.reset()

        Task { @MainActor in

            do {

                let copy = try await Task.detached(
                    priority: .userInitiated
                ) {
                    try VaultStore.shared.duplicateVault(at: url)
                }.value

                vaultBusy = nil

                loadVaults()

                infoMessage = "Creata la copia «\(copy.lastPathComponent)»: si apre con la stessa password."
                showingInfo = true

            } catch {

                vaultBusy = nil

                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }

    // MARK: - Incoming files ("Apri con VaultX")

    private var incomingTitle: String {

        pendingIncoming.count == 1
            ? "Importare «\(pendingIncoming[0].lastPathComponent)»?"
            : "Importare \(pendingIncoming.count) file?"
    }

    /// Cartella attualmente aperta nel vault (o la radice).
    private var incomingDestination: URL? {
        path.last?.url ?? activeSession?.rootDirectory
    }

    private var incomingDestinationName: String {

        if let last = path.last {
            return activeSession?.displayName(for: last.url) ?? ""
        }

        return activeSession.map { $0.displayName(for: $0.rootDirectory) } ?? ""
    }

    @ViewBuilder
    private var pendingBanner: some View {

        if !pendingIncoming.isEmpty {

            HStack(spacing: 12) {

                Image(systemName: "tray.and.arrow.down.fill")
                    .foregroundStyle(Color.accentColor)

                Text(
                    pendingIncoming.count == 1
                        ? "1 file in attesa: sblocca un vault per importarlo."
                        : "\(pendingIncoming.count) file in attesa: sblocca un vault per importarli."
                )
                .font(.footnote)

                Spacer(minLength: 0)

                Button("Scarta") {
                    discardIncoming()
                }
                .font(.footnote.weight(.semibold))
            }
            .padding(12)
            .background(.regularMaterial)
        }
    }

    private func handleIncoming(_ url: URL) {

        guard url.isFileURL else {
            return
        }

        let ext = url.pathExtension.lowercased()

        // Vault esportato (.vaultxpkg): si importa come nuovo vault.
        if ext == VaultPackage.fileExtension {

            do {

                let header = try VaultPackage.inspect(url)

                incomingVaultName = header.name
                incomingVaultPackage = IdentifiedURL(url: url)
                showingIncomingVault = true

            } catch {

                errorMessage = error.localizedDescription
                showingError = true
            }

            return
        }

        // Pacchetto protetto da password (.vaultxshare): si apre con la sua password.
        if ext == SharePackage.fileExtension {

            sharePackageToOpen = IdentifiedURL(url: url)

            return
        }

        pendingIncoming.append(url)

        if activeSession != nil {
            showingIncomingConfirm = true
        }
    }

    private func importIncoming() {

        guard let session = activeSession,
              let destination = incomingDestination,
              !pendingIncoming.isEmpty
        else {
            return
        }

        let urls = pendingIncoming

        pendingIncoming = []

        isImportingIncoming = true

        Task { @MainActor in

            let failures = await Task.detached(
                priority: .userInitiated
            ) {
                session.importFiles(urls, into: destination)
            }.value

            isImportingIncoming = false

            reloadToken = UUID()

            if !failures.isEmpty {

                errorMessage = "Impossibile importare:\n"
                    + failures.joined(separator: "\n")

                showingError = true
            }
        }
    }

    /// Scarta i file in attesa eliminando le copie ricevute.
    private func discardIncoming() {

        let urls = pendingIncoming

        pendingIncoming = []

        Task.detached(priority: .utility) {

            for url in urls where VaultSession.isDisposableCopy(url) {
                try? SecureDelete.remove(at: url)
            }
        }
    }

    private func discardIncomingVaultPackage() {

        if let package = incomingVaultPackage,
           VaultSession.isDisposableCopy(package.url) {
            try? FileManager.default.removeItem(at: package.url)
        }

        incomingVaultPackage = nil
    }

    private static func currentScreenIsCaptured() -> Bool {

        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first

        return scene?.screen.isCaptured ?? false
    }

    // MARK: - Lock

    /// Blocca il vault: azzera la chiave in memoria, elimina le copie in chiaro
    /// e torna alla lista dei vault.
    private func lockVault() {

        InactivityMonitor.shared.stop()

        activeSession?.lock()

        path.removeAll()
        activeSession = nil
        backgroundedAt = nil

        loadVaults()
    }

    private func handleScenePhase(_ phase: ScenePhase) {

        guard activeSession != nil else {
            backgroundedAt = nil
            return
        }

        switch phase {

        case .background:

            if backgroundLockSeconds == 0 {

                lockVault()

            } else if backgroundLockSeconds > 0 {

                backgroundedAt = Date()
            }

        case .active:

            if let since = backgroundedAt,
               backgroundLockSeconds > 0,
               Date().timeIntervalSince(since) >= TimeInterval(backgroundLockSeconds) {

                lockVault()
            }

            backgroundedAt = nil

        default:
            break
        }
    }

    private func startInactivityMonitor() {

        InactivityMonitor.shared.start(
            timeout: TimeInterval(inactivityLockSeconds)
        ) {
            lockVault()
        }
    }
}

// MARK: - Vault Row

private struct VaultRow: View {

    let url: URL
    let info: VaultListInfo
    let hasBiometrics: Bool

    var body: some View {

        HStack(spacing: 14) {

            VaultIconBadge(profile: info.profile)

            VStack(alignment: .leading, spacing: 3) {

                Text(url.lastPathComponent)
                    .font(.headline)

                Text(
                    info.profile.summary.isEmpty
                        ? "Vault cifrato"
                        : info.profile.summary
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                if info.failedAttempts > 0 {

                    Label(
                        info.failedAttempts == 1
                            ? "1 tentativo di sblocco fallito"
                            : "\(info.failedAttempts) tentativi di sblocco falliti",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption2)
                    .foregroundStyle(.orange)

                } else {

                    Text(statsLine)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if hasBiometrics {

                Image(systemName: BiometricAuth.shared.systemImage)
                    .foregroundStyle(.secondary)
            }

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var statsLine: String {

        var parts: [String] = []

        if let size = info.sizeBytes {

            parts.append(
                ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            )
        }

        if let lastAccess = info.lastAccess {

            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short

            parts.append(
                "Aperto " + formatter.localizedString(for: lastAccess, relativeTo: Date())
            )

        } else {

            parts.append("Mai aperto")
        }

        return parts.joined(separator: " · ")
    }
}
