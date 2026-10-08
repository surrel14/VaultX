import SwiftUI

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
    @State private var errorMessage: String?
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
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Annulla") {
                    dismiss()
                }
            }
        }
        .alert(
            "Sblocco non riuscito",
            isPresented: $showingError
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
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

    private func finish(with session: VaultSession) {

        isUnlocking = false
        password = ""

        onUnlocked(session)

        dismiss()
    }

    private func present(_ message: String) {

        errorMessage = message
        showingError = true
    }
}
