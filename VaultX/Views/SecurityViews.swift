import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Password strength

/// Indicatore di robustezza (euristico: lunghezza + varietà di caratteri).
enum PasswordStrength {

    case empty
    case weak
    case fair
    case good
    case strong

    init(_ password: String) {

        let length = password.count

        guard length > 0 else {
            self = .empty
            return
        }

        let classes = [
            password.contains { $0.isLowercase },
            password.contains { $0.isUppercase },
            password.contains { $0.isNumber },
            password.contains { !$0.isLetter && !$0.isNumber }
        ].filter { $0 }.count

        var points = 0

        if length >= 8 { points += 1 }
        if length >= 12 { points += 1 }
        if length >= 16 { points += 1 }

        points += max(0, classes - 1)

        // Una frase lunga è meglio di una parola "complicata".
        if length >= 20 { points = max(points, 4) }

        switch points {
        case 0, 1: self = .weak
        case 2, 3: self = .fair
        case 4: self = .good
        default: self = .strong
        }
    }

    var fraction: Double {

        switch self {
        case .empty: return 0
        case .weak: return 0.25
        case .fair: return 0.5
        case .good: return 0.75
        case .strong: return 1
        }
    }

    var label: String {

        switch self {
        case .empty: return ""
        case .weak: return "Debole"
        case .fair: return "Discreta"
        case .good: return "Buona"
        case .strong: return "Ottima"
        }
    }

    var color: Color {

        switch self {
        case .empty: return .gray
        case .weak: return .red
        case .fair: return .orange
        case .good: return .yellow
        case .strong: return .green
        }
    }
}

struct PasswordStrengthView: View {

    let password: String

    var body: some View {

        let strength = PasswordStrength(password)

        if strength != .empty {

            VStack(alignment: .leading, spacing: 6) {

                GeometryReader { proxy in

                    ZStack(alignment: .leading) {

                        Capsule()
                            .fill(Color(.systemGray5))

                        Capsule()
                            .fill(strength.color)
                            .frame(width: proxy.size.width * strength.fraction)
                    }
                }
                .frame(height: 6)

                Text("Robustezza: \(strength.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Change password

struct ChangePasswordView: View {

    let vaultURL: URL

    @Environment(\.dismiss)
    private var dismiss

    @State private var oldPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showingError = false
    @State private var showingDone = false

    private var canSubmit: Bool {

        !oldPassword.isEmpty
            && newPassword.count >= 8
            && newPassword == confirmPassword
            && !isWorking
    }

    var body: some View {

        NavigationStack {

            Form {

                Section {

                    SecureField("Password attuale", text: $oldPassword)
                        .textContentType(.password)
                }

                Section {

                    SecureField("Nuova password", text: $newPassword)
                        .textContentType(.newPassword)

                    SecureField("Conferma nuova password", text: $confirmPassword)
                        .textContentType(.newPassword)

                    PasswordStrengthView(password: newPassword)

                } footer: {
                    Text("Almeno 8 caratteri. I file non vengono ricifrati: cambia solo la protezione della chiave del vault, quindi l'operazione è immediata e Face ID continua a funzionare.")
                }

                Section {

                    Button {
                        submit()
                    } label: {

                        HStack {

                            Spacer()

                            if isWorking {
                                ProgressView()
                            } else {
                                Text("Cambia password")
                                    .fontWeight(.semibold)
                            }

                            Spacer()
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
            .navigationTitle("Cambia password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {

                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") {
                        dismiss()
                    }
                }
            }
        }
        .background {

            ZStack {

                Color.clear
                    .alert("Errore", isPresented: $showingError) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text(errorMessage ?? "")
                    }

                Color.clear
                    .alert("Password cambiata", isPresented: $showingDone) {
                        Button("OK") {
                            dismiss()
                        }
                    } message: {
                        Text("Da ora il vault si sblocca con la nuova password.")
                    }
            }
            .allowsHitTesting(false)
        }
    }

    private func submit() {

        guard canSubmit else {
            return
        }

        isWorking = true

        let url = vaultURL
        let oldValue = oldPassword
        let newValue = newPassword

        // PBKDF2 (due volte: verifica + nuovo wrap) è pesante: fuori dal main thread.
        Task { @MainActor in

            do {

                try await Task.detached(priority: .userInitiated) {
                    try VaultStore.shared.changePassword(
                        at: url,
                        oldPassword: oldValue,
                        newPassword: newValue
                    )
                }.value

                isWorking = false

                oldPassword = ""
                newPassword = ""
                confirmPassword = ""

                showingDone = true

            } catch {

                isWorking = false

                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }
}

// MARK: - Recovery key

struct RecoveryKeyView: View {

    let session: VaultSession

    @Environment(\.dismiss)
    private var dismiss

    @State private var hasKey = false
    @State private var generatedKey: String?
    @State private var confirmingRegenerate = false
    @State private var confirmingRemove = false
    @State private var errorMessage: String?
    @State private var showingError = false

    var body: some View {

        NavigationStack {

            Form {

                if let key = generatedKey {
                    keySection(key)
                } else {
                    statusSection
                }
            }
            .navigationTitle("Chiave di recupero")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {

                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                hasKey = VaultStore.shared.hasRecoveryKey(at: session.vaultURL)
            }
        }
        .background {

            ZStack {

                Color.clear
                    .alert("Errore", isPresented: $showingError) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text(errorMessage ?? "")
                    }

                Color.clear
                    .alert("Generare una nuova chiave?", isPresented: $confirmingRegenerate) {

                        Button("Genera", role: .destructive) {
                            generate()
                        }

                        Button("Annulla", role: .cancel) {}

                    } message: {
                        Text("La chiave precedente smetterà di funzionare.")
                    }

                Color.clear
                    .alert("Rimuovere la chiave di recupero?", isPresented: $confirmingRemove) {

                        Button("Rimuovi", role: .destructive) {
                            remove()
                        }

                        Button("Annulla", role: .cancel) {}

                    } message: {
                        Text("Se dimentichi la password non potrai più recuperare il vault.")
                    }
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: - Sections

    private var statusSection: some View {

        Group {

            Section {

                Label(
                    hasKey
                        ? "Chiave di recupero attiva"
                        : "Nessuna chiave di recupero",
                    systemImage: hasKey ? "checkmark.shield" : "exclamationmark.shield"
                )

            } footer: {
                Text("Senza password e senza chiave di recupero il contenuto del vault è perso per sempre: non esiste alcun modo per aggirare la cifratura. La chiave di recupero ti permette di impostare una nuova password se dimentichi quella attuale.")
            }

            Section {

                Button {

                    if hasKey {
                        confirmingRegenerate = true
                    } else {
                        generate()
                    }

                } label: {
                    Label(
                        hasKey ? "Genera una nuova chiave" : "Genera chiave di recupero",
                        systemImage: "key.horizontal"
                    )
                }

                if hasKey {

                    Button(role: .destructive) {
                        confirmingRemove = true
                    } label: {
                        Label("Rimuovi chiave di recupero", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func keySection(_ key: String) -> some View {

        Group {

            Section {

                Text(key)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .textSelection(.enabled)

            } header: {
                Text("La tua chiave di recupero")
            } footer: {
                Text("Salvala ora in un posto sicuro (per esempio un gestore di password) e non condividerla: chi la possiede può aprire il vault. Non verrà più mostrata.")
            }

            Section {

                Button {
                    copy(key)
                } label: {
                    Label("Copia (si cancella dopo 2 minuti)", systemImage: "doc.on.doc")
                }

                ShareLink(item: key) {
                    Label("Condividi…", systemImage: "square.and.arrow.up")
                }

                Button {
                    generatedKey = nil
                    hasKey = true
                } label: {
                    Label("L'ho salvata", systemImage: "checkmark.circle")
                }
            }
        }
    }

    // MARK: - Actions

    private func generate() {

        do {

            generatedKey = try VaultStore.shared.createRecoveryKey(for: session)
            hasKey = true

        } catch {

            errorMessage = error.localizedDescription
            showingError = true
        }
    }

    private func remove() {

        do {

            try VaultStore.shared.removeRecoveryKey(at: session.vaultURL)
            hasKey = false

        } catch {

            errorMessage = error.localizedDescription
            showingError = true
        }
    }

    /// Appunti solo locali (niente Handoff) e con scadenza.
    private func copy(_ key: String) {

        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: key]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(120)
            ]
        )
    }
}

// MARK: - Reset password (forgot password)

struct ResetPasswordView: View {

    let vaultURL: URL

    /// Chiamata dopo il reset con la nuova password (per sbloccare subito il vault).
    let onReset: (String) -> Void

    @Environment(\.dismiss)
    private var dismiss

    @State private var recoveryKey = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showingError = false

    private var canSubmit: Bool {

        !recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && newPassword.count >= 8
            && newPassword == confirmPassword
            && !isWorking
    }

    var body: some View {

        NavigationStack {

            Form {

                Section {

                    TextField("Chiave di recupero", text: $recoveryKey, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .lineLimit(2...4)

                } footer: {
                    Text("Quella che hai salvato quando l'hai generata (13 gruppi di 4 caratteri).")
                }

                Section {

                    SecureField("Nuova password", text: $newPassword)
                        .textContentType(.newPassword)

                    SecureField("Conferma nuova password", text: $confirmPassword)
                        .textContentType(.newPassword)

                    PasswordStrengthView(password: newPassword)
                }

                Section {

                    Button {
                        submit()
                    } label: {

                        HStack {

                            Spacer()

                            if isWorking {
                                ProgressView()
                            } else {
                                Text("Reimposta password")
                                    .fontWeight(.semibold)
                            }

                            Spacer()
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
            .navigationTitle("Password dimenticata")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {

                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") {
                        dismiss()
                    }
                }
            }
            .alert("Errore", isPresented: $showingError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func submit() {

        guard canSubmit else {
            return
        }

        isWorking = true

        let url = vaultURL
        let key = recoveryKey
        let password = newPassword

        Task { @MainActor in

            do {

                try await Task.detached(priority: .userInitiated) {
                    try VaultStore.shared.resetPassword(
                        at: url,
                        recoveryKey: key,
                        newPassword: password
                    )
                }.value

                isWorking = false

                dismiss()

                onReset(password)

            } catch {

                isWorking = false

                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }
}
