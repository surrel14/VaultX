import Foundation

final class VaultStore {

    static let shared = VaultStore()

    private let fileManager = FileManager.default
    private let appGroupIdentifier = "group.com.example.VaultX"
    private let customRootURL: URL?

    /// `rootURL` serve solo ai test: permette di usare una cartella temporanea.
    init(rootURL: URL? = nil) {
        self.customRootURL = rootURL
    }

    var appGroupURL: URL {

        fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )
        ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
    }

    var rootURL: URL {

        customRootURL
        ?? appGroupURL.appendingPathComponent(
            "Vaults",
            isDirectory: true
        )
    }

    func prepare() throws {

        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Create

    func createVault(
        named name: String,
        password: String
    ) throws -> URL {

        try prepare()

        let safeName = sanitizedName(name)

        guard !safeName.isEmpty else {
            throw VaultStoreError.invalidName
        }

        guard password.count >= 8 else {
            throw VaultStoreError.weakPassword
        }

        let vault = rootURL.appendingPathComponent(
            safeName,
            isDirectory: true
        )

        guard !fileManager.fileExists(atPath: vault.path) else {
            throw VaultStoreError.alreadyExists
        }

        try fileManager.createDirectory(
            at: vault,
            withIntermediateDirectories: true
        )

        try fileManager.createDirectory(
            at: dataURL(for: vault),
            withIntermediateDirectories: true
        )

        // Un eventuale elemento Keychain di un vault omonimo eliminato in passato
        // conterrebbe una chiave sbagliata.
        KeychainStore.delete(account: keychainAccount(for: vault))

        var masterKey = try VaultCrypto.generateMasterKey()

        defer {
            VaultSession.wipe(&masterKey)
        }

        let wrappedKey = try VaultCrypto.wrapMasterKey(
            masterKey,
            password: password
        )

        try wrappedKey.write(
            to: vault.appendingPathComponent("masterkey.vaultx"),
            options: [.atomic, .completeFileProtection]
        )

        let manifest = VaultManifest(
            version: 2,
            name: safeName,
            createdAt: Date()
        )

        let manifestData = try JSONEncoder().encode(manifest)

        let encryptedManifest = try VaultCrypto.encrypt(
            manifestData,
            using: masterKey
        )

        try encryptedManifest.write(
            to: vault.appendingPathComponent("vault.manifest"),
            options: [.atomic, .completeFileProtection]
        )

        return vault
    }

    // MARK: - Unlock

    func unlockVault(
        at url: URL,
        password: String
    ) throws -> VaultSession {

        let wrapped = try Data(
            contentsOf: url.appendingPathComponent("masterkey.vaultx")
        )

        var masterKey = try VaultCrypto.unwrapMasterKey(
            wrapped,
            password: password
        )

        defer {
            VaultSession.wipe(&masterKey)
        }

        return try openSession(at: url, masterKey: masterKey)
    }

    /// Sblocca con la master key custodita nel Keychain (protetta da biometria).
    /// Mostra il prompt di Face ID / Touch ID e blocca il thread finché l'utente
    /// risponde: chiamare fuori dal main thread.
    func unlockVaultWithBiometrics(at url: URL) throws -> VaultSession {

        let account = keychainAccount(for: url)

        guard var masterKey = try KeychainStore.load(
            account: account,
            reason: "Sblocca il vault «\(url.lastPathComponent)»"
        ) else {
            throw VaultStoreError.biometricUnavailable
        }

        defer {
            VaultSession.wipe(&masterKey)
        }

        do {
            return try openSession(at: url, masterKey: masterKey)
        } catch {
            // Chiave non più valida (es. vault ricreato): la rimuoviamo.
            KeychainStore.delete(account: account)
            throw VaultStoreError.biometricUnavailable
        }
    }

    private func openSession(
        at url: URL,
        masterKey: Data
    ) throws -> VaultSession {

        let encryptedManifest = try Data(
            contentsOf: url.appendingPathComponent("vault.manifest")
        )

        let manifestData = try VaultCrypto.decrypt(
            encryptedManifest,
            using: masterKey
        )

        let manifest = try JSONDecoder().decode(
            VaultManifest.self,
            from: manifestData
        )

        return VaultSession(
            vaultURL: url,
            manifest: manifest,
            masterKey: masterKey
        )
    }

    // MARK: - Biometric unlock (Keychain)

    func keychainAccount(for vaultURL: URL) -> String {
        "masterkey." + vaultURL.lastPathComponent
    }

    func isBiometricUnlockEnabled(for vaultURL: URL) -> Bool {
        KeychainStore.exists(account: keychainAccount(for: vaultURL))
    }

    func enableBiometricUnlock(for session: VaultSession) throws {

        var key = try session.masterKeyData()

        defer {
            VaultSession.wipe(&key)
        }

        try KeychainStore.save(
            key,
            account: keychainAccount(for: session.vaultURL),
            accessControl: try KeychainStore.makeBiometricAccessControl()
        )
    }

    func disableBiometricUnlock(for vaultURL: URL) {
        KeychainStore.delete(account: keychainAccount(for: vaultURL))
    }

    // MARK: - List / Delete

    func vaults() throws -> [URL] {

        try prepare()

        return try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .contentModificationDateKey
            ],
            options: [.skipsHiddenFiles]
        )
        .filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        .sorted {
            $0.lastPathComponent.localizedCaseInsensitiveCompare(
                $1.lastPathComponent
            ) == .orderedAscending
        }
    }

    /// Elimina il vault (sovrascrittura best effort + rimozione) e la sua chiave Keychain.
    func deleteVault(at url: URL) throws {

        disableBiometricUnlock(for: url)

        try SecureDelete.remove(at: url)
    }

    func dataURL(for vault: URL) -> URL {

        vault.appendingPathComponent(
            "data",
            isDirectory: true
        )
    }

    private func sanitizedName(_ name: String) -> String {

        let invalid = CharacterSet(charactersIn: "/\\:\0")

        return name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: invalid)
            .joined(separator: "-")
    }
}

// MARK: - Errors

enum VaultStoreError: LocalizedError {

    case invalidName
    case weakPassword
    case alreadyExists
    case itemAlreadyExists
    case locked
    case invalidLocation
    case invalidMove
    case biometricUnavailable

    var errorDescription: String? {

        switch self {

        case .invalidName:
            return "Nome non valido."

        case .weakPassword:
            return "Usa una password di almeno 8 caratteri."

        case .alreadyExists:
            return "Esiste già un vault con questo nome."

        case .itemAlreadyExists:
            return "Esiste già un elemento con questo nome."

        case .locked:
            return "Il vault è bloccato."

        case .invalidLocation:
            return "Percorso non valido all'interno del vault."

        case .invalidMove:
            return "Non puoi spostare l'elemento in questa cartella."

        case .biometricUnavailable:
            return "Lo sblocco biometrico non è più disponibile per questo vault (i dati biometrici sono cambiati). Usa la password."
        }
    }
}

// MARK: - Vault Manifest

struct VaultManifest: Codable, Equatable {

    let version: Int
    let name: String
    let createdAt: Date
}
