import Foundation
import CryptoKit
import UIKit
import ImageIO
import PDFKit

// MARK: - Vault Item

/// Un elemento del vault: un file cifrato (`nome.ext.vltx`) oppure una cartella.
struct VaultItem: Identifiable, Hashable {

    let url: URL
    let isFolder: Bool

    /// Nome originale (senza `.vltx`).
    let name: String

    /// Dimensione del contenuto in chiaro (0 per le cartelle).
    let size: Int64

    let modified: Date?

    var id: URL { url }

    var fileExtension: String {
        (name as NSString).pathExtension.lowercased()
    }
}

// MARK: - Vault Session

/// Sessione di un vault sbloccato.
///
/// La master key è tenuta in un buffer allocato a mano che viene AZZERATO
/// (`memset_s`) e liberato da `lock()`. Per ogni operazione si crea una
/// `SymmetricKey` temporanea, che CryptoKit azzera quando viene rilasciata.
final class VaultSession: @unchecked Sendable {

    let vaultURL: URL
    let manifest: VaultManifest

    private let stateLock = NSLock()
    private var keyBuffer: UnsafeMutableRawBufferPointer?
    private let thumbnailCache = NSCache<NSString, UIImage>()

    var rootDirectory: URL {
        vaultURL.appendingPathComponent("data", isDirectory: true)
    }

    init(
        vaultURL: URL,
        manifest: VaultManifest,
        masterKey: Data
    ) {

        self.vaultURL = vaultURL
        self.manifest = manifest

        let buffer = UnsafeMutableRawBufferPointer.allocate(
            byteCount: masterKey.count,
            alignment: 16
        )

        masterKey.withUnsafeBytes { source in
            if let from = source.baseAddress, let to = buffer.baseAddress {
                to.copyMemory(from: from, byteCount: masterKey.count)
            }
        }

        self.keyBuffer = buffer
        self.thumbnailCache.countLimit = 300
    }

    deinit {
        wipeKey()
    }

    // MARK: - Key management

    var isLocked: Bool {

        stateLock.lock()
        defer { stateLock.unlock() }

        return keyBuffer == nil
    }

    /// Blocca il vault: azzera la chiave in memoria, svuota la cache delle
    /// anteprime ed elimina le copie in chiaro in tmp.
    func lock() {

        wipeKey()

        thumbnailCache.removeAllObjects()

        Self.removeTemporaryFiles()
    }

    private func wipeKey() {

        stateLock.lock()
        defer { stateLock.unlock() }

        guard let buffer = keyBuffer else {
            return
        }

        if let base = buffer.baseAddress {
            _ = memset_s(base, buffer.count, 0, buffer.count)
        }

        buffer.deallocate()
        keyBuffer = nil
    }

    private func requireUnlocked() throws {

        stateLock.lock()
        defer { stateLock.unlock() }

        guard keyBuffer != nil else {
            throw VaultStoreError.locked
        }
    }

    private func makeKey() throws -> SymmetricKey {

        stateLock.lock()
        defer { stateLock.unlock() }

        guard let buffer = keyBuffer else {
            throw VaultStoreError.locked
        }

        return SymmetricKey(data: UnsafeRawBufferPointer(buffer))
    }

    /// Copia della master key (serve solo per salvarla nel Keychain).
    /// Il chiamante deve azzerarla con `VaultSession.wipe(_:)` appena possibile.
    func masterKeyData() throws -> Data {

        stateLock.lock()
        defer { stateLock.unlock() }

        guard let buffer = keyBuffer, let base = buffer.baseAddress else {
            throw VaultStoreError.locked
        }

        return Data(bytes: base, count: buffer.count)
    }

    /// Azzera in place i byte di un `Data` (best effort: funziona se il buffer
    /// non è condiviso con altre copie).
    static func wipe(_ data: inout Data) {

        guard !data.isEmpty else {
            return
        }

        data.resetBytes(in: 0..<data.count)
    }

    // MARK: - Names

    static func originalName(of encryptedURL: URL) -> String {

        encryptedURL.pathExtension.lowercased() == "vltx"
            ? encryptedURL.deletingPathExtension().lastPathComponent
            : encryptedURL.lastPathComponent
    }

    static func validatedName(_ raw: String) throws -> String {

        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        let invalid = CharacterSet(charactersIn: "/\\:\0")

        guard !name.isEmpty,
              name != ".",
              name != "..",
              name.utf8.count <= 200,
              name.rangeOfCharacter(from: invalid) == nil
        else {
            throw VaultStoreError.invalidName
        }

        return name
    }

    private static func sanitizedImportName(_ raw: String) -> String {

        let invalid = CharacterSet(charactersIn: "/\\:\0")

        let cleaned = raw
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            return "File"
        }

        return cleaned
    }

    // MARK: - Location checks

    private func isInsideVault(_ url: URL) -> Bool {

        let root = rootDirectory.resolvingSymlinksInPath().path
        let path = url.resolvingSymlinksInPath().path

        return path == root || path.hasPrefix(root + "/")
    }

    private func isRoot(_ url: URL) -> Bool {

        url.resolvingSymlinksInPath().path
            == rootDirectory.resolvingSymlinksInPath().path
    }

    // MARK: - Listing

    func items(in directory: URL) throws -> [VaultItem] {

        try requireUnlocked()

        guard isInsideVault(directory) else {
            throw VaultStoreError.invalidLocation
        }

        let fileManager = FileManager.default

        if isRoot(directory), !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]

        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: []
        )

        var result: [VaultItem] = []

        for url in urls {

            let values = try? url.resourceValues(forKeys: Set(keys))

            if values?.isDirectory == true {

                result.append(
                    VaultItem(
                        url: url,
                        isFolder: true,
                        name: url.lastPathComponent,
                        size: 0,
                        modified: values?.contentModificationDate
                    )
                )

            } else if url.pathExtension.lowercased() == "vltx" {

                let encryptedSize = Int64(values?.fileSize ?? 0)

                result.append(
                    VaultItem(
                        url: url,
                        isFolder: false,
                        name: Self.originalName(of: url),
                        size: max(0, encryptedSize - Int64(VaultCrypto.envelopeOverhead)),
                        modified: values?.contentModificationDate
                    )
                )
            }
        }

        return result
    }

    private func nameExists(
        _ name: String,
        in directory: URL,
        excluding excluded: URL? = nil
    ) -> Bool {

        guard let existing = try? items(in: directory) else {
            return false
        }

        return existing.contains { item in

            if let excluded,
               item.url.standardizedFileURL.path
                == excluded.standardizedFileURL.path {
                return false
            }

            return item.name.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    /// "foto.jpg" -> "foto (1).jpg" se esiste già.
    private func uniqueName(
        for name: String,
        isFolder: Bool,
        in directory: URL
    ) -> String {

        guard nameExists(name, in: directory) else {
            return name
        }

        let nsName = name as NSString
        let ext = isFolder ? "" : nsName.pathExtension
        let base = isFolder ? name : nsName.deletingPathExtension

        var counter = 1

        while true {

            let candidate = ext.isEmpty
                ? "\(base) (\(counter))"
                : "\(base) (\(counter)).\(ext)"

            if !nameExists(candidate, in: directory) {
                return candidate
            }

            counter += 1
        }
    }

    // MARK: - Folders

    @discardableResult
    func createFolder(
        named name: String,
        in directory: URL
    ) throws -> URL {

        try requireUnlocked()

        guard isInsideVault(directory) else {
            throw VaultStoreError.invalidLocation
        }

        let clean = try Self.validatedName(name)

        guard !nameExists(clean, in: directory) else {
            throw VaultStoreError.itemAlreadyExists
        }

        let url = directory.appendingPathComponent(
            clean,
            isDirectory: true
        )

        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )

        return url
    }

    // MARK: - Rename

    @discardableResult
    func renameItem(
        _ item: VaultItem,
        to newName: String
    ) throws -> URL {

        try requireUnlocked()

        guard isInsideVault(item.url), !isRoot(item.url) else {
            throw VaultStoreError.invalidLocation
        }

        let clean = try Self.validatedName(newName)

        if clean == item.name {
            return item.url
        }

        let directory = item.url.deletingLastPathComponent()

        guard !nameExists(clean, in: directory, excluding: item.url) else {
            throw VaultStoreError.itemAlreadyExists
        }

        let destination = directory.appendingPathComponent(
            item.isFolder ? clean : clean + ".vltx",
            isDirectory: item.isFolder
        )

        try FileManager.default.moveItem(
            at: item.url,
            to: destination
        )

        return destination
    }

    // MARK: - Move

    func canMove(
        _ item: VaultItem,
        to folder: URL
    ) -> Bool {

        guard isInsideVault(item.url),
              !isRoot(item.url),
              isInsideVault(folder)
        else {
            return false
        }

        let target = folder.resolvingSymlinksInPath().path

        let parent = item.url
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .path

        // Già nella cartella di destinazione.
        if target == parent {
            return false
        }

        // Una cartella non può finire dentro se stessa o in un suo discendente.
        if item.isFolder {

            let source = item.url.resolvingSymlinksInPath().path

            if target == source || target.hasPrefix(source + "/") {
                return false
            }
        }

        return true
    }

    @discardableResult
    func moveItem(
        _ item: VaultItem,
        to folder: URL
    ) throws -> URL {

        try requireUnlocked()

        guard canMove(item, to: folder) else {
            throw VaultStoreError.invalidMove
        }

        let name = uniqueName(
            for: item.name,
            isFolder: item.isFolder,
            in: folder
        )

        let destination = folder.appendingPathComponent(
            item.isFolder ? name : name + ".vltx",
            isDirectory: item.isFolder
        )

        try FileManager.default.moveItem(
            at: item.url,
            to: destination
        )

        return destination
    }

    /// Quanti degli elementi possono essere spostati nella cartella indicata.
    func movableCount(
        _ items: [VaultItem],
        to folder: URL
    ) -> Int {

        items.filter { canMove($0, to: folder) }.count
    }

    /// Sposta più elementi. Quelli che non si possono spostare (già nella cartella,
    /// o una cartella dentro se stessa) vengono saltati. Restituisce un messaggio
    /// per ogni errore.
    func moveItems(
        _ items: [VaultItem],
        to folder: URL
    ) -> [String] {

        var failures: [String] = []

        for item in topLevel(items) where canMove(item, to: folder) {

            do {
                try moveItem(item, to: folder)
            } catch {
                failures.append("\(item.name): \(error.localizedDescription)")
            }
        }

        return failures
    }

    /// Toglie dalla lista gli elementi contenuti in una cartella anch'essa selezionata
    /// (verrebbero spostati/eliminati insieme alla cartella).
    private func topLevel(_ items: [VaultItem]) -> [VaultItem] {

        let folderPaths = items
            .filter { $0.isFolder }
            .map { $0.url.resolvingSymlinksInPath().path }

        return items.filter { item in

            let path = item.url.resolvingSymlinksInPath().path

            return !folderPaths.contains { path.hasPrefix($0 + "/") }
        }
    }

    // MARK: - Delete

    /// Elimina più elementi. Restituisce un messaggio per ogni errore.
    func deleteItems(_ items: [VaultItem]) -> [String] {

        var failures: [String] = []

        for item in topLevel(items) {

            do {
                try deleteItem(item)
            } catch {
                failures.append("\(item.name): \(error.localizedDescription)")
            }
        }

        return failures
    }

    /// Elimina un file o una cartella (con tutto il contenuto): sovrascrive i
    /// file con dati casuali (best effort) e poi li rimuove.
    func deleteItem(_ item: VaultItem) throws {

        try requireUnlocked()

        guard isInsideVault(item.url), !isRoot(item.url) else {
            throw VaultStoreError.invalidLocation
        }

        try SecureDelete.remove(at: item.url)
    }

    // MARK: - Import

    @discardableResult
    func importFile(
        at sourceURL: URL,
        into directory: URL
    ) throws -> URL {

        try requireUnlocked()

        guard isInsideVault(directory) else {
            throw VaultStoreError.invalidLocation
        }

        let key = try makeKey()

        let accessed = sourceURL.startAccessingSecurityScopedResource()

        defer {
            if accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let clearData = try Data(
            contentsOf: sourceURL,
            options: .mappedIfSafe
        )

        let encrypted = try VaultCrypto.encrypt(
            clearData,
            using: key
        )

        let name = uniqueName(
            for: Self.sanitizedImportName(sourceURL.lastPathComponent),
            isFolder: false,
            in: directory
        )

        let destination = directory.appendingPathComponent(name + ".vltx")

        try encrypted.write(
            to: destination,
            options: [.atomic, .completeFileProtection]
        )

        return destination
    }

    /// Cifra più file. Restituisce un messaggio per ogni file non importato
    /// (array vuoto = tutto ok). Le copie temporanee del document picker
    /// vengono eliminate in modo sicuro.
    func importFiles(
        _ urls: [URL],
        into directory: URL
    ) -> [String] {

        var failures: [String] = []

        for url in urls {

            do {
                _ = try importFile(at: url, into: directory)
            } catch {
                failures.append(
                    "\(url.lastPathComponent): \(error.localizedDescription)"
                )
            }

            removeTemporaryCopy(url)
        }

        return failures
    }

    /// Copie in chiaro create per noi dal sistema (picker con `asCopy: true`,
    /// foto importate, "Apri con…"): stanno in tmp o nella cartella Inbox
    /// dell'app. I file originali dell'utente non vengono mai toccati.
    static func isDisposableCopy(_ url: URL) -> Bool {

        let path = url.resolvingSymlinksInPath().path

        let tmp = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath().path

        if path.hasPrefix(tmp + "/") {
            return true
        }

        let home = URL(fileURLWithPath: NSHomeDirectory())
            .resolvingSymlinksInPath().path

        return path.hasPrefix(home + "/")
            && url.deletingLastPathComponent().lastPathComponent.hasSuffix("Inbox")
    }

    private func removeTemporaryCopy(_ url: URL) {

        if Self.isDisposableCopy(url) {
            try? SecureDelete.remove(at: url)
        }
    }

    // MARK: - Open / Export (copie temporanee in chiaro)

    static var openDirectory: URL {

        FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultXOpen", isDirectory: true)
    }

    /// Decifra un file in una sottocartella temporanea unica, mantenendo il
    /// nome originale (serve ad anteprima e condivisione).
    func decryptToTemporaryFile(_ encryptedURL: URL) throws -> URL {

        try requireUnlocked()

        guard isInsideVault(encryptedURL) else {
            throw VaultStoreError.invalidLocation
        }

        let key = try makeKey()

        let encrypted = try Data(
            contentsOf: encryptedURL,
            options: .mappedIfSafe
        )

        let clear = try VaultCrypto.decrypt(
            encrypted,
            using: key
        )

        let directory = Self.openDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )

        let destination = directory.appendingPathComponent(
            Self.originalName(of: encryptedURL)
        )

        try clear.write(
            to: destination,
            options: [.atomic, .completeFileProtection]
        )

        return destination
    }

    /// Elimina (con sovrascrittura best effort, in background) le copie in
    /// chiaro presenti in tmp. Considera solo ciò che esiste ora, così non
    /// tocca file creati subito dopo.
    static func removeTemporaryFiles() {

        let tmp = FileManager.default.temporaryDirectory

        var targets: [URL] = []

        for name in ["VaultXOpen", "VaultXImport"] {

            let directory = tmp.appendingPathComponent(
                name,
                isDirectory: true
            )

            if let children = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            ) {
                targets.append(contentsOf: children)
            }
        }

        guard !targets.isEmpty else {
            return
        }

        DispatchQueue.global(qos: .utility).async {

            for target in targets {
                try? SecureDelete.remove(at: target)
            }
        }
    }

    // MARK: - Thumbnails (solo in RAM)

    private static let thumbnailExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "pdf"
    ]

    static func supportsThumbnail(_ item: VaultItem) -> Bool {
        !item.isFolder && thumbnailExtensions.contains(item.fileExtension)
    }

    /// Miniatura di immagini e PDF. Il file viene decifrato SOLO in memoria
    /// (niente copie su disco) e la miniatura resta in una cache in RAM
    /// che viene svuotata al blocco del vault.
    func thumbnail(for item: VaultItem) -> UIImage? {

        guard Self.supportsThumbnail(item),
              item.size <= 25 * 1024 * 1024
        else {
            return nil
        }

        let cacheKey = "\(item.url.path)|\(item.modified?.timeIntervalSince1970 ?? 0)" as NSString

        if let cached = thumbnailCache.object(forKey: cacheKey) {
            return cached
        }

        guard let key = try? makeKey(),
              let encrypted = try? Data(contentsOf: item.url, options: .mappedIfSafe),
              let clear = try? VaultCrypto.decrypt(encrypted, using: key)
        else {
            return nil
        }

        let image: UIImage?

        if item.fileExtension == "pdf" {
            image = Self.pdfThumbnail(from: clear)
        } else {
            image = Self.imageThumbnail(from: clear)
        }

        if let image {
            thumbnailCache.setObject(image, forKey: cacheKey)
        }

        return image
    }

    private static func imageThumbnail(from data: Data) -> UIImage? {

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 160
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }

    private static func pdfThumbnail(from data: Data) -> UIImage? {

        guard let document = PDFDocument(data: data),
              let page = document.page(at: 0)
        else {
            return nil
        }

        return page.thumbnail(
            of: CGSize(width: 160, height: 160),
            for: .mediaBox
        )
    }
}
