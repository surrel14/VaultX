import SwiftUI
import UIKit

struct UnlockVaultView: View {

    @Environment(\.dismiss)
    private var dismiss

    let vaultURL: URL

    let onUnlocked: (VaultSession) -> Void

    @State private var password = ""
    @State private var isUnlocking = false
    @State private var biometricsEnabled = false
    @State private var enableBiometrics = false
    @State private var didAutoPrompt = false
    @State private var hasRecoveryKey = false
    @State private var showingReset = false

    // Aggiornamento dei vault nel vecchio formato
    @State private var legacySession: VaultSession?
    @State private var showingMigrationConfirm = false
    @State private var isMigrating = false
    @StateObject private var migration = MigrationProgress()
    @State private var errorMessage: String?
    @State private var errorTitle = "Sblocco non riuscito"
    @State private var showingError = false

    private var biometrics: BiometricAuth {
        BiometricAuth.shared
    }

    var body: some View {

        Form {

            Section {

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

                        Text(vaultURL.lastPathComponent)
                            .font(.headline)

                        Text("Vault bloccato")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {

                SecureField(
                    "Password",
                    text: $password
                )
                .textContentType(.password)
                .submitLabel(.go)
                .onSubmit {
                    unlockWithPassword()
                }

                if hasRecoveryKey {

                    Button("Password dimenticata?") {
                        showingReset = true
                    }
                    .font(.footnote)
                }
            }

            if biometricsEnabled {

                Section {

                    Button {
                        unlockWithBiometrics()
                    } label: {
                        Label(
                            "Sblocca con \(biometrics.title)",
                            systemImage: biometrics.systemImage
                        )
                    }
                    .disabled(isUnlocking)
                }

            } else if biometrics.isAvailable {

                Section {

                    Toggle(isOn: $enableBiometrics) {
                        Label(
                            "Usa \(biometrics.title) per questo vault",
                            systemImage: biometrics.systemImage
                        )
                    }

                } footer: {
                    Text("La chiave del vault verrà custodita nel Keychain di questo dispositivo, protetta da \(biometrics.title). Se i dati biometrici cambiano, dovrai usare di nuovo la password.")
                }
            }

            Section {

                Button {
                    unlockWithPassword()
                } label: {

                    HStack {

                        Spacer()

                        if isUnlocking {
                            ProgressView()
                        } else {
                            Text("Sblocca")
                                .fontWeight(.semibold)
                        }

                        Spacer()
                    }
                }
                .disabled(password.isEmpty || isUnlocking)
            }
        }
        .navigationTitle("Sblocca vault")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(isUnlocking || isMigrating)
        .overlay {
            migrationOverlay
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Annulla") {
                    dismiss()
                }
                .disabled(isMigrating)
            }
        }
        .background {

            ZStack {

                Color.clear
                    .alert(
                        errorTitle,
                        isPresented: $showingError
                    ) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text(errorMessage ?? "")
                    }

                Color.clear
                    .alert(
                        "Aggiornare il vault?",
                        isPresented: $showingMigrationConfirm
                    ) {

                        Button("Aggiorna") {
                            startMigration()
                        }

                        Button("Annulla", role: .cancel) {
                            cancelMigration()
                        }

                    } message: {
                        Text("Questo vault usa il formato precedente. Per continuare va aggiornato al nuovo formato, che cifra anche i nomi di file e cartelle e supporta i file di grandi dimensioni. La password non cambia. L'operazione ricifra tutti i file e non è reversibile: può richiedere un po' di tempo, tieni l'app aperta.")
                    }
            }
            .allowsHitTesting(false)
        }
        .sheet(isPresented: $showingReset) {

            ResetPasswordView(vaultURL: vaultURL) { newPassword in
                password = newPassword
                unlockWithPassword()
            }
        }
        .onAppear {

            hasRecoveryKey = VaultStore.shared.hasRecoveryKey(at: vaultURL)

            biometricsEnabled = VaultStore.shared
                .isBiometricUnlockEnabled(for: vaultURL)

            // Se Face ID è attivo per questo vault, lo proponiamo subito.
            if biometricsEnabled, !didAutoPrompt {
                didAutoPrompt = true
                unlockWithBiometrics()
            }
        }
    }

    // MARK: - Password

    private func unlockWithPassword() {

        guard !password.isEmpty, !isUnlocking else {
            return
        }

        isUnlocking = true

        let url = vaultURL
        let entered = password
        let wantsBiometrics = enableBiometrics

        // PBKDF2 è pesante: fuori dal main thread, così la UI resta fluida.
        Task { @MainActor in

            do {

                let session = try await Task.detached(
                    priority: .userInitiated
                ) {
                    try VaultStore.shared.unlockVault(
                        at: url,
                        password: entered
                    )
                }.value

                if wantsBiometrics {
                    // Se fallisce, il vault si sblocca comunque con la password:
                    // l'utente potrà riprovare dal menu del vault.
                    try? VaultStore.shared.enableBiometricUnlock(for: session)
                }

                finish(with: session)

            } catch {

                isUnlocking = false

                if case VaultCryptoError.authenticationFailed = error {

                    // Il tentativo fallito è già stato registrato dallo store.
                    let attempts = SecurityLog.shared.failedAttempts(
                        vault: url.lastPathComponent
                    )

                    if let alert = UnlockFailureMessage.make(
                        attempts: attempts,
                        hasRecoveryKey: hasRecoveryKey
                    ) {

                        UINotificationFeedbackGenerator()
                            .notificationOccurred(.warning)

                        present(alert.message, title: alert.title)

                        return
                    }
                }

                present(error.localizedDescription)
            }
        }
    }

    // MARK: - Biometrics

    private func unlockWithBiometrics() {

        guard !isUnlocking else {
            return
        }

        isUnlocking = true

        let url = vaultURL

        // La lettura dal Keychain mostra il prompt e blocca il thread.
        Task { @MainActor in

            do {

                let session = try await Task.detached(
                    priority: .userInitiated
                ) {
                    try VaultStore.shared.unlockVaultWithBiometrics(at: url)
                }.value

                finish(with: session)

            } catch let error as KeychainError where error.isCancellation {

                isUnlocking = false

            } catch VaultStoreError.biometricUnavailable {

                isUnlocking = false
                biometricsEnabled = false

                present(VaultStoreError.biometricUnavailable.localizedDescription)

            } catch {

                isUnlocking = false

                present(error.localizedDescription)
            }
        }
    }

    // MARK: - Helpers

    /// Sblocco riuscito: se il vault è nel vecchio formato prima va aggiornato.
    private func finish(with session: VaultSession) {

        isUnlocking = false

        if session.isLegacy {

            legacySession = session
            showingMigrationConfirm = true

            return
        }

        complete(with: session)
    }

    private func complete(with session: VaultSession) {

        password = ""

        onUnlocked(session)

        dismiss()
    }

    // MARK: - Migration

    private func startMigration() {

        guard let session = legacySession else {
            return
        }

        isMigrating = true
        migration.update(done: 0, total: 0)

        let tracker = migration

        Task { @MainActor in

            do {

                try await Task.detached(priority: .userInitiated) {

                    try session.migrateFromLegacy { done, total in
                        tracker.update(done: done, total: total)
                    }

                }.value

                isMigrating = false
                legacySession = nil

                SecurityLog.shared.record(
                    .vaultMigrated,
                    vault: session.vaultURL.lastPathComponent
                )

                complete(with: session)

            } catch {

                isMigrating = false
                legacySession = nil

                session.lock()

                present(error.localizedDescription)
            }
        }
    }

    private func cancelMigration() {

        legacySession?.lock()
        legacySession = nil
    }

    @ViewBuilder
    private var migrationOverlay: some View {

        if isMigrating {

            ZStack {

                Color.black
                    .opacity(0.35)
                    .ignoresSafeArea()

                VStack(spacing: 14) {

                    ProgressView(
                        value: Double(migration.done),
                        total: Double(max(migration.total, 1))
                    )

                    Text("Aggiornamento del vault…")
                        .font(.headline)

                    Text(
                        migration.total > 0
                            ? "\(migration.done) di \(migration.total) file"
                            : "Preparazione…"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: 280)
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: 16)
                )
            }
        }
    }

    private func present(
        _ message: String,
        title: String = "Sblocco non riuscito"
    ) {

        errorTitle = title
        errorMessage = message
        showingError = true
    }
}


// MARK: - Migration progress

/// Raccoglie l'avanzamento della migrazione (chiamato da un thread in background)
/// e lo pubblica sul main thread per la UI.
final class MigrationProgress: ObservableObject, @unchecked Sendable {

    @Published private(set) var done = 0
    @Published private(set) var total = 0

    func update(done: Int, total: Int) {

        DispatchQueue.main.async {
            self.done = done
            self.total = total
        }
    }
}


// MARK: - Failed attempts message

/// Messaggio mostrato quando i tentativi di sblocco falliti consecutivi sono 3 o più.
enum UnlockFailureMessage {

    static let threshold = 3

    static func make(
        attempts: Int,
        hasRecoveryKey: Bool
    ) -> (title: String, message: String)? {

        guard attempts >= threshold else {
            return nil
        }

        var message = "Password errata. Gli ultimi \(attempts) tentativi di sblocco non sono riusciti e sono stati registrati nel registro di sicurezza.\n\nSe non sei stato tu, cambia la password del vault appena possibile."

        if hasRecoveryKey {

            message += "\n\nSe l'hai dimenticata, usa «Password dimenticata?» con la tua chiave di recupero."

        } else {

            message += "\n\nSe l'hai dimenticata: senza password e senza chiave di recupero il contenuto del vault non si può recuperare."
        }

        return ("Attenzione: \(attempts) tentativi falliti", message)
    }
}
