import Foundation
import Combine

final class VaultStore {
    static let shared = VaultStore()
    private init() {}

    private let fileManager = FileManager.default
    private let appGroupIdentifier = "group.com.example.VaultX"

    var appGroupURL: URL {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    var rootURL: URL {
        appGroupURL.appendingPathComponent("Vaults", isDirectory: true)
    }

    func prepare() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func createVault(named name: String, password: String) throws -> URL {
        try prepare()
        let safeName = sanitizedName(name)
        guard !safeName.isEmpty else { throw VaultStoreError.invalidName }
        guard password.count >= 8 else { throw VaultStoreError.weakPassword }

        let vault = rootURL.appendingPathComponent(safeName, isDirectory: true)
        guard !fileManager.fileExists(atPath: vault.path) else { throw VaultStoreError.alreadyExists }

        try fileManager.createDirectory(at: vault, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: dataURL(for: vault), withIntermediateDirectories: true)

        let masterKey = try VaultCrypto.generateMasterKey()
        let wrappedKey = try VaultCrypto.wrapMasterKey(masterKey, password: password)
        try wrappedKey.write(to: vault.appendingPathComponent("masterkey.vaultx"), options: [.atomic])

        let manifest = VaultManifest(version: 2, name: safeName, createdAt: Date())
        let manifestData = try JSONEncoder().encode(manifest)
        let encryptedManifest = try VaultCrypto.encrypt(manifestData, using: masterKey)
        try encryptedManifest.write(to: vault.appendingPathComponent("vault.manifest"), options: [.atomic])

        return vault
    }

    func unlockVault(at url: URL, password: String) throws -> VaultSession {
        let wrapped = try Data(contentsOf: url.appendingPathComponent("masterkey.vaultx"))
        let masterKey = try VaultCrypto.unwrapMasterKey(wrapped, password: password)
        let encryptedManifest = try Data(contentsOf: url.appendingPathComponent("vault.manifest"))
        let manifestData = try VaultCrypto.decrypt(encryptedManifest, using: masterKey)
        let manifest = try JSONDecoder().decode(VaultManifest.self, from: manifestData)
        return VaultSession(vaultURL: url, manifest: manifest, masterKey: masterKey)
    }

    func vaults() throws -> [URL] {
        try prepare()
        return try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    func dataURL(for vault: URL) -> URL {
        vault.appendingPathComponent("data", isDirectory: true)
    }

    private func sanitizedName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:\0")
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: invalid).joined(separator: "-")
    }
}

final class VaultSession: ObservableObject {
    let vaultURL: URL
    let manifest: VaultManifest
    private let masterKey: Data

    init(vaultURL: URL, manifest: VaultManifest, masterKey: Data) {
        self.vaultURL = vaultURL
        self.manifest = manifest
        self.masterKey = masterKey
    }

    var masterKeyForKeychain: Data { masterKey }

    func encryptedData(for clearData: Data) throws -> Data {
        try VaultCrypto.encrypt(clearData, using: masterKey)
    }

    func clearData(from encryptedData: Data) throws -> Data {
        try VaultCrypto.decrypt(encryptedData, using: masterKey)
    }

    func encryptFile(at sourceURL: URL, named name: String? = nil) throws -> URL {
        let clearData = try Data(contentsOf: sourceURL)
        let encrypted = try encryptedData(for: clearData)
        let outputName = (name ?? sourceURL.lastPathComponent) + ".vltx"
        let destination = VaultStore.shared.dataURL(for: vaultURL).appendingPathComponent(outputName)
        try encrypted.write(to: destination, options: [.atomic])
        return destination
    }

    func decryptFile(at encryptedURL: URL, to destinationURL: URL) throws {
        let encrypted = try Data(contentsOf: encryptedURL)
        let clear = try clearData(from: encrypted)
        try clear.write(to: destinationURL, options: [.atomic])
    }

    func encryptedFiles() throws -> [URL] {
        let dataURL = VaultStore.shared.dataURL(for: vaultURL)
        return try FileManager.default.contentsOfDirectory(at: dataURL, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "vltx" }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    func lock() {
        // The master key only lives in this session object. Dropping the session releases it.
    }
}

enum VaultStoreError: LocalizedError {
    case invalidName
    case weakPassword
    case alreadyExists

    var errorDescription: String? {
        switch self {
        case .invalidName: return "Nome vault non valido."
        case .weakPassword: return "Usa una password di almeno 8 caratteri."
        case .alreadyExists: return "Esiste già un vault con questo nome."
        }
    }
}

struct VaultManifest: Codable, Equatable {
    let version: Int
    let name: String
    let createdAt: Date
}
