import Foundation
import Security
import LocalAuthentication

struct KeychainError: LocalizedError {

    let status: OSStatus

    /// L'utente ha annullato il prompt di Face ID / Touch ID.
    var isCancellation: Bool {
        status == errSecUserCanceled
    }

    var errorDescription: String? {

        switch status {
        case errSecUserCanceled:
            return "Operazione annullata."
        case errSecAuthFailed:
            return "Autenticazione non riuscita."
        case errSecInteractionNotAllowed:
            return "Sblocca il dispositivo e riprova."
        case errSecNotAvailable:
            return "Il Keychain non è disponibile."
        default:
            return "Errore Keychain (\(status))."
        }
    }
}

/// Wrapper minimale del Keychain per salvare la master key di un vault
/// protetta da biometria (Face ID / Touch ID).
enum KeychainStore {

    static var service: String {
        Bundle.main.bundleIdentifier ?? "com.example.VaultX"
    }

    // MARK: - Access control

    /// La chiave è leggibile solo con la biometria *attuale*: se cambiano
    /// i volti/le impronte registrati, l'elemento diventa inutilizzabile.
    /// `ThisDeviceOnly`: non viene sincronizzata né finisce nei backup.
    static func makeBiometricAccessControl() throws -> SecAccessControl {

        var error: Unmanaged<CFError>?

        guard let control = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            &error
        ) else {

            if let cfError = error?.takeRetainedValue() {
                throw cfError
            }

            throw KeychainError(status: errSecParam)
        }

        return control
    }

    // MARK: - Save

    static func save(
        _ value: Data,
        account: String,
        accessControl: SecAccessControl
    ) throws {

        // Sostituisce un eventuale elemento precedente.
        delete(account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: value,
            kSecAttrAccessControl as String: accessControl
        ]

        let status = SecItemAdd(query as CFDictionary, nil)

        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
    }

    // MARK: - Load

    /// Legge la chiave. Il sistema mostra il prompt di Face ID / Touch ID e la
    /// chiamata BLOCCA il thread finché l'utente risponde: non usarla sul main thread.
    /// Restituisce `nil` se l'elemento non esiste (o è stato invalidato).
    static func load(
        account: String,
        reason: String
    ) throws -> Data? {

        let context = LAContext()
        context.localizedReason = reason

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }

        return result as? Data
    }

    // MARK: - Exists / Delete

    /// Controlla se esiste l'elemento SENZA richiedere la biometria
    /// (legge solo gli attributi, non il segreto).
    static func exists(account: String) -> Bool {

        let context = LAContext()
        context.interactionNotAllowed = true

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)

        return status == errSecSuccess
            || status == errSecInteractionNotAllowed
    }

    static func delete(account: String) {

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)
    }
}
