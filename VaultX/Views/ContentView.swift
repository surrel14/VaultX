import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var vaults: [URL] = []
    @State private var showingCreate = false
    @State private var selectedVault: URL?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Group {
                if vaults.isEmpty {
                    ContentUnavailableView {
                        Label("Nessun vault", systemImage: "lock.doc")
                    } description: {
                        Text("Crea un vault cifrato per proteggere i tuoi file.")
                    } actions: {
                        Button("Crea vault") { showingCreate = true }
                    }
                } else {
                    List(vaults, id: \.self) { vault in
                        Button {
                            selectedVault = vault
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "lock.fill")
                                    .font(.title3)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(vault.lastPathComponent)
                                        .font(.headline)
                                    Text("Vault cifrato")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("VaultX")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingCreate = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Crea vault")
                }
            }
            .task { loadVaults() }
            .sheet(isPresented: $showingCreate) {
                CreateVaultView(onCreated: loadVaults)
            }
            .sheet(item: Binding(
                get: { selectedVault.map(VaultURLItem.init) },
                set: { selectedVault = $0?.url }
            )) { item in
                UnlockVaultView(vaultURL: item.url)
            }
            .alert("VaultX", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("OK") { message = nil }
            } message: {
                Text(message ?? "")
            }
        }
    }

    private func loadVaults() {
        do {
            vaults = try VaultStore.shared.vaults()
        } catch {
            message = error.localizedDescription
        }
    }
}

private struct VaultURLItem: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct CreateVaultView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var enableFaceID = true
    @State private var error: String?
    let onCreated: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Vault") {
                    TextField("Nome", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Password") {
                    SecureField("Password", text: $password)
                    SecureField("Ripeti password", text: $confirmPassword)
                    Text("La password deve contenere almeno 8 caratteri.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Usa Face ID per lo sblocco", isOn: $enableFaceID)
                } footer: {
                    Text("La chiave del vault resta protetta dal Keychain del dispositivo.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Button("Crea vault") { create() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.count < 8 || password != confirmPassword)
                }
            }
            .navigationTitle("Nuovo vault")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
            }
        }
    }

    private func create() {
        do {
            let url = try VaultStore.shared.createVault(named: name, password: password)
            if enableFaceID {
                let session = try VaultStore.shared.unlockVault(at: url, password: password)
                let access = try KeychainStore.makeBiometricAccessControl()
                try KeychainStore.save(session.masterKeyForKeychain, account: "vault.\(url.lastPathComponent)", accessControl: access)
            }
            onCreated()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct UnlockVaultView: View {
    @Environment(\.dismiss) private var dismiss
    let vaultURL: URL
    @State private var password = ""
    @State private var session: VaultSession?
    @State private var error: String?
    @State private var isUnlocking = false
    @State private var files: [URL] = []
    @State private var showingImporter = false

    var body: some View {
        NavigationStack {
            Group {
                if let session {
                    VaultFilesView(session: session, files: files, refresh: refresh, importFile: { showingImporter = true })
                } else {
                    unlockForm
                }
            }
            .navigationTitle(vaultURL.lastPathComponent)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Chiudi") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                importFiles(result)
            }
            .task { await tryBiometricUnlock() }
        }
    }

    private var unlockForm: some View {
        Form {
            Section("Sblocco") {
                SecureField("Password", text: $password)
                    .textContentType(.password)
                Button {
                    unlockWithPassword()
                } label: {
                    if isUnlocking { ProgressView() } else { Text("Sblocca") }
                }
                .disabled(password.isEmpty || isUnlocking)
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
    }

    private func unlockWithPassword() {
        isUnlocking = true
        defer { isUnlocking = false }
        do {
            let unlocked = try VaultStore.shared.unlockVault(at: vaultURL, password: password)
            session = unlocked
            refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func tryBiometricUnlock() async {
        let account = "vault.\(vaultURL.lastPathComponent)"
        guard (try? KeychainStore.load(account: account)) != nil else { return }
        do {
            guard try await BiometricAuth.shared.authenticate(reason: "Sblocca il vault \(vaultURL.lastPathComponent)") else { return }
            guard let masterKey = try KeychainStore.load(account: account) else { return }
            let encryptedManifest = try Data(contentsOf: vaultURL.appendingPathComponent("vault.manifest"))
            let manifestData = try VaultCrypto.decrypt(encryptedManifest, using: masterKey)
            let manifest = try JSONDecoder().decode(VaultManifest.self, from: manifestData)
            session = VaultSession(vaultURL: vaultURL, manifest: manifest, masterKey: masterKey)
            refresh()
        } catch {
            // Fall back to password unlock without presenting a second error.
        }
    }

    private func refresh() {
        guard let session else { return }
        files = (try? session.encryptedFiles()) ?? []
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        guard let session else { return }
        do {
            for source in try result.get() {
                let accessed = source.startAccessingSecurityScopedResource()
                defer { if accessed { source.stopAccessingSecurityScopedResource() } }
                _ = try session.encryptFile(at: source)
            }
            refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct VaultFilesView: View {
    let session: VaultSession
    let files: [URL]
    let refresh: () -> Void
    let importFile: () -> Void
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Button { importFile() } label: {
                    Label("Importa file", systemImage: "plus")
                }
            }
            Section("File cifrati") {
                if files.isEmpty {
                    Text("Il vault è vuoto.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(files, id: \.self) { file in
                        Label(displayName(file), systemImage: "doc.lock.fill")
                    }
                }
            }
        }
        .refreshable { refresh() }
    }

    private func displayName(_ url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? url.lastPathComponent : name
    }
}
