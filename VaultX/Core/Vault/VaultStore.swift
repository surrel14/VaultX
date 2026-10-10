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
        password: String,
        profile: VaultProfile = .default
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

        try? saveProfile(profile, for: vault)

        SecurityLog.shared.record(.vaultCreated, vault: vault.lastPathComponent)

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

        var masterKey: Data

        do {

            masterKey = try VaultCrypto.unwrapMasterKey(
                wrapped,
                password: password
            )

        } catch VaultCryptoError.authenticationFailed {

            SecurityLog.shared.record(.unlockFailed, vault: url.lastPathComponent)

            throw VaultCryptoError.authenticationFailed
        }

        defer {
            VaultSession.wipe(&masterKey)
        }

        let session = try openSession(at: url, masterKey: masterKey)

        recordUnlock(of: url, method: "password")

        return session
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

            let session = try openSession(at: url, masterKey: masterKey)

            recordUnlock(of: url, method: "biometria")

            return session

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

        SecurityLog.shared.record(.biometricEnabled, vault: session.vaultURL.lastPathComponent)
    }

    func disableBiometricUnlock(for vaultURL: URL, logEvent: Bool = true) {

        KeychainStore.delete(account: keychainAccount(for: vaultURL))

        if logEvent {
            SecurityLog.shared.record(.biometricDisabled, vault: vaultURL.lastPathComponent)
        }
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

        SecurityLog.shared.record(.passwordChanged, vault: url.lastPathComponent)
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

        SecurityLog.shared.record(.recoveryKeyCreated, vault: session.vaultURL.lastPathComponent)

        return RecoveryKey.format(secret)
    }

    func removeRecoveryKey(at url: URL) throws {

        let target = recoveryKeyURL(for: url)

        if fileManager.fileExists(atPath: target.path) {

            try SecureDelete.remove(at: target)

            SecurityLog.shared.record(.recoveryKeyRemoved, vault: url.lastPathComponent)
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

        SecurityLog.shared.record(
            .passwordReset,
            vault: url.lastPathComponent,
            detail: "Password reimpostata con la chiave di recupero"
        )
    }

    // MARK: - Activity

    private func lastAccessKey(_ vaultURL: URL) -> String {
        "vaultx.lastAccess." + vaultURL.lastPathComponent
    }

    /// Ultimo sblocco riuscito su questo dispositivo (non viaggia con il vault).
    func lastAccess(of vaultURL: URL) -> Date? {
        UserDefaults.standard.object(forKey: lastAccessKey(vaultURL)) as? Date
    }

    private func recordUnlock(of url: URL, method: String) {

        UserDefaults.standard.set(Date(), forKey: lastAccessKey(url))

        SecurityLog.shared.record(
            .unlockSucceeded,
            vault: url.lastPathComponent,
            detail: "Sblocco con " + method
        )
    }

    // MARK: - Profile

    private func profileURL(for vault: URL) -> URL {
        vault.appendingPathComponent("profile.json")
    }

    /// Profilo salvato (o quello predefinito se manca o è illeggibile).
    func profile(for vault: URL) -> VaultProfile {

        guard let data = try? Data(contentsOf: profileURL(for: vault)),
              let profile = try? JSONDecoder().decode(VaultProfile.self, from: data)
        else {
            return .default
        }

        return profile
    }

    func saveProfile(_ profile: VaultProfile, for vault: URL) throws {

        var cleaned = profile

        cleaned.summary = String(
            profile.summary
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(200)
        )

        if !VaultProfile.icons.contains(cleaned.icon) {
            cleaned.icon = VaultProfile.default.icon
        }

        if !VaultProfile.colorKeys.contains(cleaned.color) {
            cleaned.color = VaultProfile.default.color
        }

        try JSONEncoder().encode(cleaned).write(
            to: profileURL(for: vault),
            options: [.atomic, .completeFileProtection]
        )
    }

    /// Spazio occupato dal vault su disco (tutto cifrato). Può richiedere tempo
    /// per vault grandi: chiamare fuori dal main thread.
    func diskUsage(of vault: URL) -> Int64 {

        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]

        guard let enumerator = fileManager.enumerator(
            at: vault,
            includingPropertiesForKeys: keys
        ) else {
            return 0
        }

        var total: Int64 = 0

        for case let url as URL in enumerator {

            let values = try? url.resourceValues(forKeys: Set(keys))

            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }

        return total
    }

    /// Profilo, ultimo accesso e tentativi falliti (veloce: senza la dimensione).
    func quickInfo(for vault: URL) -> VaultListInfo {

        VaultListInfo(
            profile: profile(for: vault),
            sizeBytes: nil,
            lastAccess: lastAccess(of: vault),
            failedAttempts: SecurityLog.shared.failedAttempts(vault: vault.lastPathComponent)
        )
    }

    // MARK: - Export / import / duplicate

    /// Esporta il vault (anche bloccato) in un pacchetto `.vaultxpkg`.
    func exportVault(
        at url: URL,
        to destination: URL,
        progress: ((Int64, Int64) -> Void)? = nil
    ) throws {

        try VaultPackage.export(
            vaultURL: url,
            to: destination,
            progress: progress
        )

        SecurityLog.shared.record(
            .vaultExported,
            vault: url.lastPathComponent,
            detail: "Pacchetto .vaultxpkg"
        )
    }

    /// Importa un pacchetto creando un nuovo vault (mai sovrascrive uno esistente).
    @discardableResult
    func importVaultPackage(
        from source: URL,
        progress: ((Int64, Int64) -> Void)? = nil
    ) throws -> URL {

        try prepare()

        let url = try VaultPackage.importPackage(
            from: source,
            into: rootURL,
            progress: progress
        )

        // Un eventuale elemento Keychain omonimo conterrebbe una chiave sbagliata.
        KeychainStore.delete(account: keychainAccount(for: url))

        SecurityLog.shared.record(.vaultImported, vault: url.lastPathComponent)

        return url
    }

    /// Duplica un vault (copia identica, stessa password) con il nome "<nome> (copia)".
    @discardableResult
    func duplicateVault(at url: URL) throws -> URL {

        try prepare()

        let base = url.lastPathComponent + " (copia)"

        var destination = rootURL.appendingPathComponent(base, isDirectory: true)
        var counter = 2

        while fileManager.fileExists(atPath: destination.path) {

            destination = rootURL.appendingPathComponent(
                "\(url.lastPathComponent) (copia \(counter))",
                isDirectory: true
            )

            counter += 1
        }

        try fileManager.copyItem(at: url, to: destination)

        KeychainStore.delete(account: keychainAccount(for: destination))

        SecurityLog.shared.record(
            .vaultDuplicated,
            vault: url.lastPathComponent,
            detail: "Creata la copia «\(destination.lastPathComponent)»"
        )

        return destination
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

        disableBiometricUnlock(for: url, logEvent: false)

        try SecureDelete.remove(at: url)

        SecurityLog.shared.record(.vaultDeleted, vault: url.lastPathComponent)
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
