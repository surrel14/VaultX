import SwiftUI

// ============================================================
// MARK: - Create Vault
// ============================================================

struct CreateVaultView: View {

    @Environment(\.dismiss)
    private var dismiss

    @State private var vaultName = ""

    @State private var password = ""

    @State private var confirmPassword = ""
    @State private var isCreating = false

    @State private var errorMessage: String?

    @State private var showingError = false

    let onCreated: () -> Void


    var body: some View {

        NavigationStack {

            Form {

                Section {

                    TextField(
                        "Nome vault",
                        text: $vaultName
                    )
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()

                    SecureField(
                        "Password",
                        text: $password
                    )
                    .textContentType(.newPassword)

                    SecureField(
                        "Conferma password",
                        text: $confirmPassword
                    )
                    .textContentType(.newPassword)

                    PasswordStrengthView(password: password)

                } header: {

                    Text("Nuovo vault")

                } footer: {

                    Text(
                        "La password deve contenere almeno 8 caratteri."
                    )
                }


                Section {

                    Button {

                        createVault()

                    } label: {

                        HStack {

                            Spacer()

                            if isCreating {
                                ProgressView()
                            } else {
                                Text(
                                    "Crea vault"
                                )
                                .fontWeight(
                                    .semibold
                                )
                            }

                            Spacer()
                        }
                    }
                    .disabled(
                        !canCreate
                    )
                }
            }
            .navigationTitle(
                "Crea Vault"
            )
            .navigationBarTitleDisplayMode(
                .inline
            )
            .toolbar {

                ToolbarItem(
                    placement:
                        .navigationBarLeading
                ) {

                    Button(
                        "Annulla"
                    ) {

                        dismiss()
                    }
                }
            }
            .alert(
                "Errore",
                isPresented:
                    $showingError
            ) {

                Button(
                    "OK",
                    role: .cancel
                ) {}

            } message: {

                Text(
                    errorMessage ??
                    "Errore durante la creazione."
                )
            }
        }
    }


    private var canCreate: Bool {

        !vaultName
            .trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )
            .isEmpty
        &&
        password.count >= 8
        &&
        password == confirmPassword
        &&
        !isCreating
    }


    private func createVault() {

        let name =
            vaultName.trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )

        guard !name.isEmpty else {

            showError(
                "Inserisci un nome per il vault."
            )

            return
        }

        guard password.count >= 8 else {

            showError(
                "La password deve contenere almeno 8 caratteri."
            )

            return
        }

        guard password == confirmPassword else {

            showError(
                "Le password non coincidono."
            )

            return
        }


        isCreating = true

        let enteredPassword = password

        // PBKDF2 (600k iterazioni) è pesante: fuori dal main thread.
        Task { @MainActor in

            do {

                _ = try await Task.detached(
                    priority: .userInitiated
                ) {
                    try VaultStore.shared.createVault(
                        named: name,
                        password: enteredPassword
                    )
                }.value

                isCreating = false

                onCreated()

                dismiss()

            } catch {

                isCreating = false

                showError(
                    error.localizedDescription
                )
            }
        }
    }


    private func showError(
        _ message: String
    ) {

        errorMessage = message

        showingError = true
    }
}
