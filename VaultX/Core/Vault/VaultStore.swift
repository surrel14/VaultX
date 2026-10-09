import Foundation
import CryptoKit

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
            at: contentURL(for: vault),
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
            version: 3,
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

        // Indice cifrato iniziale (vuoto): nomi e cartelle vivranno solo qui.
        let emptyIndex = try VaultIndex().serialized()

        let encryptedIndex = try VaultCrypto.encrypt(
            emptyIndex,
            using: VaultCrypto.indexKey(masterKey: SymmetricKey(data: masterKey))
        )

        try encryptedIndex.write(
            to: vault.appendingPathComponent("index.vaultx"),
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

        let session = VaultSession(
            vaultURL: url,
            manifest: manifest,
            masterKey: masterKey
        )

        do {
            // Carica (e quindi verifica) l'indice; per i vault v0.2 non fa nulla.
            try session.prepare()
        } catch {
            session.lock()
            throw error
        }

        return session
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

    // MARK: - Change password

    private func wrappedKeyURL(for vault: URL) -> URL {
        vault.appendingPathComponent("masterkey.vaultx")
    }

    /// Cambia la password: la master key resta la stessa (quindi i file non
    /// vengono toccati e Face ID continua a funzionare), cambia solo l'involucro.
    /// Un vault con il vecchio formato viene aggiornato al KDF più forte.
    func changePassword(
        at url: URL,
        oldPassword: String,
        newPassword: String
    ) throws {

        guard newPassword.count >= 8 else {
            throw VaultStoreError.weakPassword
        }

        let wrappedURL = wrappedKeyURL(for: url)

        var masterKey = try VaultCrypto.unwrapMasterKey(
            try Data(contentsOf: wrappedURL),
            password: oldPassword
        )

        defer {
            VaultSession.wipe(&masterKey)
        }

        try VaultCrypto.wrapMasterKey(
            masterKey,
            password: newPassword
        )
        .write(
            to: wrappedURL,
            options: [.atomic, .completeFileProtection]
        )
    }

    // MARK: - Recovery key

    private func recoveryKeyURL(for vault: URL) -> URL {
        vault.appendingPathComponent("recovery.vaultx")
    }

    func hasRecoveryKey(at url: URL) -> Bool {
        fileManager.fileExists(atPath: recoveryKeyURL(for: url).path)
    }

    /// Genera (o rigenera, invalidando la precedente) la chiave di recupero.
    /// Restituisce il testo da mostrare UNA volta all'utente: non viene salvato da nessuna parte.
    func createRecoveryKey(for session: VaultSession) throws -> String {

        var masterKey = try session.masterKeyData()
        var secret = try RecoveryKey.generate()

        defer {
            VaultSession.wipe(&masterKey)
            VaultSession.wipe(&secret)
        }

        try VaultCrypto.wrapMasterKey(
            masterKey,
            recoverySecret: secret
        )
        .write(
            to: recoveryKeyURL(for: session.vaultURL),
            options: [.atomic, .completeFileProtection]
        )

        return RecoveryKey.format(secret)
    }

    func removeRecoveryKey(at url: URL) throws {

        let target = recoveryKeyURL(for: url)

        if fileManager.fileExists(atPath: target.path) {
            try SecureDelete.remove(at: target)
        }
    }

    /// Password dimenticata: con la chiave di recupero si imposta una nuova password.
    func resetPassword(
        at url: URL,
        recoveryKey: String,
        newPassword: String
    ) throws {

        guard newPassword.count >= 8 else {
            throw VaultStoreError.weakPassword
        }

        guard var secret = RecoveryKey.parse(recoveryKey) else {
            throw VaultStoreError.invalidRecoveryKey
        }

        defer {
            VaultSession.wipe(&secret)
        }

        guard hasRecoveryKey(at: url) else {
            throw VaultStoreError.noRecoveryKey
        }

        var masterKey: Data

        do {

            masterKey = try VaultCrypto.unwrapMasterKey(
                try Data(contentsOf: recoveryKeyURL(for: url)),
                recoverySecret: secret
            )

        } catch VaultCryptoError.authenticationFailed {

            throw VaultStoreError.invalidRecoveryKey
        }

        defer {
            VaultSession.wipe(&masterKey)
        }

        // La chiave deve davvero aprire questo vault.
        _ = try VaultCrypto.decrypt(
            try Data(contentsOf: url.appendingPathComponent("vault.manifest")),
            using: masterKey
        )

        try VaultCrypto.wrapMasterKey(
            masterKey,
            password: newPassword
        )
        .write(
            to: wrappedKeyURL(for: url),
            options: [.atomic, .completeFileProtection]
        )
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

    /// Cartella piatta con i file cifrati (formato v3).
    func contentURL(for vault: URL) -> URL {

        vault.appendingPathComponent(
            "files",
            isDirectory: true
        )
    }

    /// Cartella con i nomi in chiaro del vecchio formato (v0.2).
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
    case invalidRecoveryKey
    case noRecoveryKey
    case migrationRequired
    case migrationFailed(String)

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

        case .invalidRecoveryKey:
            return "Chiave di recupero non valida."

        case .noRecoveryKey:
            return "Questo vault non ha una chiave di recupero."

        case .migrationRequired:
            return "Questo vault usa il formato precedente e deve essere aggiornato prima di poterlo usare."

        case .migrationFailed(let detail):
            return "Aggiornamento del vault non riuscito (il vault è rimasto nel formato precedente e non è stato modificato): \(detail)"
        }
    }
}

// MARK: - Vault Manifest

struct VaultManifest: Codable, Equatable {

    let version: Int
    let name: String
    let createdAt: Date
}
