import SwiftUI
import UIKit

// MARK: - Navigation helpers

/// Wrapper Identifiable per presentare lo sheet di sblocco con `.sheet(item:)`.
struct VaultSelection: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Valore di navigazione per le sottocartelle di un vault aperto.
struct VaultFolder: Hashable {
    let url: URL
}

// MARK: - ContentView

struct ContentView: View {

    @Environment(\.scenePhase)
    private var scenePhase

    @AppStorage(AppSettings.backgroundLockKey)
    private var backgroundLockSeconds = AppSettings.defaultBackgroundLockSeconds

    @AppStorage(AppSettings.inactivityLockKey)
    private var inactivityLockSeconds = AppSettings.defaultInactivityLockSeconds

    @State private var vaults: [URL] = []
    @State private var biometricVaults: Set<URL> = []

    @State private var activeSession: VaultSession?
    @State private var path: [VaultFolder] = []

    @State private var unlockTarget: VaultSelection?
    @State private var showingCreateVault = false
    @State private var showingSettings = false

    @State private var vaultPendingDeletion: URL?
    @State private var showingVaultDeleteConfirm = false

    @State private var backgroundedAt: Date?

    /// Incrementato quando il contenuto del vault cambia da fuori (import da "Apri con…").
    @State private var reloadToken = UUID()

    /// File ricevuti da altre app ("Apri con VaultX") in attesa di essere importati.
    @State private var pendingIncoming: [URL] = []
    @State private var showingIncomingConfirm = false
    @State private var isImportingIncoming = false

    @State private var isScreenCaptured = false

    @State private var errorMessage: String?
    @State private var showingError = false

    var body: some View {

        NavigationStack(path: $path) {

            root
                .navigationDestination(for: VaultFolder.self) { folder in

                    if let session = activeSession {

                        VaultBrowserView(
                            session: session,
                            directory: folder.url,
                            title: folder.url.lastPathComponent,
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
            incomingImportOverlay
        }
        .background {
            presentations
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
                title: session.manifest.name,
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

                Button {
                    showingCreateVault = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Nuovo vault")
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

            Text("Crea un vault protetto da password per cifrare i tuoi file.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                showingCreateVault = true
            } label: {
                Label("Crea vault", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
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
                        hasBiometrics: biometricVaults.contains(vault)
                    )
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {

                    Button(role: .destructive) {
                        vaultPendingDeletion = vault
                        showingVaultDeleteConfirm = true
                    } label: {
                        Label("Elimina", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Presentations

    private var presentations: some View {

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
    /// centro di controllo...) per non mostrare i file negli snapshot di iOS.
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

    // MARK: - Vaults

    private func loadVaults() {

        do {

            let list = try VaultStore.shared.vaults()

            vaults = list

            biometricVaults = Set(
                list.filter {
                    VaultStore.shared.isBiometricUnlockEnabled(for: $0)
                }
            )

        } catch {

            errorMessage = error.localizedDescription
            showingError = true
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
            return last.url.lastPathComponent
        }

        return activeSession?.manifest.name ?? ""
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

    @ViewBuilder
    private var incomingImportOverlay: some View {

        if isImportingIncoming {

            ZStack {

                Color.black
                    .opacity(0.25)
                    .ignoresSafeArea()

                ProgressView("Cifratura in corso…")
                    .padding(20)
                    .background(
                        .regularMaterial,
                        in: RoundedRectangle(cornerRadius: 14)
                    )
            }
        }
    }

    private func handleIncoming(_ url: URL) {

        guard url.isFileURL else {
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
    let hasBiometrics: Bool

    var body: some View {

        HStack(spacing: 14) {

            Image(systemName: "lock.fill")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(
                    Color.accentColor.gradient,
                    in: RoundedRectangle(
                        cornerRadius: 10,
                        style: .continuous
                    )
                )

            VStack(alignment: .leading, spacing: 3) {

                Text(url.lastPathComponent)
                    .font(.headline)

                Text("Vault cifrato")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
}
