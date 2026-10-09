import Foundation
import CryptoKit
import UIKit
import ImageIO
import PDFKit

// MARK: - Vault Item

/// Un elemento del vault visto dall'interfaccia: un file o una cartella.
///
/// `url` è un identificatore stabile: per i file è il percorso reale del file cifrato
/// (`files/<ID>.vltx`), per le cartelle un percorso "virtuale" (`files/<ID>`) che non
/// esiste su disco. Rinominare o spostare un elemento non cambia mai il suo `url`.
struct VaultItem: Identifiable, Hashable {

    let url: URL
    let isFolder: Bool

    /// Nome originale (vive solo nell'indice cifrato).
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

/// Sessione di un vault sbloccato (formato v3).
///
/// - La master key è tenuta in un buffer allocato a mano che viene AZZERATO
///   (`memset_s`) e liberato da `lock()`. Per ogni operazione si crea una
///   `SymmetricKey` temporanea, che CryptoKit azzera quando viene rilasciata.
/// - Nomi, cartelle e struttura stanno nell'indice cifrato (`index.vaultx`);
///   su disco restano solo file `files/<ID>.vltx` con nomi casuali.
final class VaultSession: @unchecked Sendable {

    let vaultURL: URL
    let manifest: VaultManifest

    // Chiave
    private let stateLock = NSLock()
    private var keyBuffer: UnsafeMutableRawBufferPointer?

    // Indice (protetto da indexLock; ricorsivo perché le operazioni si annidano)
    let indexLock = NSRecursiveLock()
    private var index: VaultIndex?
    private var legacy: Bool
    private var indexLoadedFromBackup = false

    private let thumbnailCache = NSCache<NSString, UIImage>()

    // MARK: Paths

    /// Cartella piatta con i file cifrati (v3).
    var contentDirectory: URL {
        vaultURL.appendingPathComponent("files", isDirectory: true)
    }

    /// Radice (virtuale) del vault: coincide con la cartella dei file cifrati.
    var rootDirectory: URL {
        contentDirectory
    }

    /// Cartella con nomi in chiaro dei vault v0.2 (solo per la migrazione).
    var legacyDataDirectory: URL {
        vaultURL.appendingPathComponent("data", isDirectory: true)
    }

    private var indexURL: URL {
        vaultURL.appendingPathComponent("index.vaultx")
    }

    private var indexBackupURL: URL {
        vaultURL.appendingPathComponent("index.vaultx.bak")
    }

    init(
        vaultURL: URL,
        manifest: VaultManifest,
        masterKey: Data
    ) {

        self.vaultURL = vaultURL
        self.manifest = manifest

        self.legacy = !FileManager.default.fileExists(
            atPath: vaultURL.appendingPathComponent("index.vaultx").path
        )

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

    /// `true` se il vault usa ancora il formato v0.2 e va aggiornato (`migrateFromLegacy`).
    var isLegacy: Bool {

        indexLock.lock()
        defer { indexLock.unlock() }

        return legacy
    }

    /// Blocca il vault: azzera la chiave in memoria, dimentica l'indice (nomi),
    /// svuota la cache delle anteprime ed elimina le copie in chiaro in tmp.
    func lock() {

        wipeKey()

        indexLock.lock()
        index = nil
        indexLock.unlock()

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

    func requireUnlocked() throws {

        stateLock.lock()
        defer { stateLock.unlock() }

        guard keyBuffer != nil else {
            throw VaultStoreError.locked
        }
    }

    func makeKey() throws -> SymmetricKey {

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

    /// Nome originale di un file del vecchio formato ("foto.jpg.vltx" -> "foto.jpg").
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

    // MARK: - URL <-> node

    func fileURL(for id: UUID) -> URL {
        contentDirectory.appendingPathComponent(id.uuidString + ".vltx")
    }

    private func url(for node: VaultNode) -> URL {

        node.isFolder
            ? contentDirectory.appendingPathComponent(node.id.uuidString, isDirectory: true)
            : fileURL(for: node.id)
    }

    /// ID del nodo a cui si riferisce l'URL; `nil` per la radice.
    private func nodeID(for url: URL) throws -> UUID? {

        let content = contentDirectory.standardizedFileURL.path

        if url.standardizedFileURL.path == content {
            return nil
        }

        guard url.deletingLastPathComponent().standardizedFileURL.path == content else {
            throw VaultStoreError.invalidLocation
        }

        var name = url.lastPathComponent

        if name.lowercased().hasSuffix(".vltx") {
            name = String(name.dropLast(5))
        }

        guard let id = UUID(uuidString: name) else {
            throw VaultStoreError.invalidLocation
        }

        return id
    }

    private static func requireFolder(
        _ id: UUID?,
        in index: VaultIndex
    ) throws {

        guard let id else {
            return
        }

        guard let node = index.nodes[id], node.isFolder else {
            throw VaultStoreError.invalidLocation
        }
    }

    private func makeItem(_ node: VaultNode) -> VaultItem {

        VaultItem(
            url: url(for: node),
            isFolder: node.isFolder,
            name: node.name,
            size: node.size,
            modified: node.modified
        )
    }

    /// Nome da mostrare per una cartella (o per la radice).
    func displayName(for url: URL) -> String {

        guard let id = try? nodeID(for: url) else {
            return manifest.name
        }

        let name: String? = try? withIndex { index in
            index.nodes[id]?.name
        }

        return name ?? manifest.name
    }

    // MARK: - Index (load / save)

    private func readIndexFile(
        at url: URL,
        key: SymmetricKey
    ) throws -> VaultIndex {

        let encrypted = try Data(contentsOf: url)

        let plain = try VaultCrypto.decrypt(
            encrypted,
            using: VaultCrypto.indexKey(masterKey: key)
        )

        return try VaultIndex(serialized: plain)
    }

    /// Da chiamare con `indexLock` acquisito.
    private func loadIndexLocked() throws {

        if legacy {
            throw VaultStoreError.migrationRequired
        }

        if index != nil {
            return
        }

        let key = try makeKey()

        do {

            index = try readIndexFile(at: indexURL, key: key)
            indexLoadedFromBackup = false

        } catch {

            // Indice principale illeggibile: si prova la copia precedente.
            guard let backup = try? readIndexFile(at: indexBackupURL, key: key) else {
                throw error
            }

            index = backup
            indexLoadedFromBackup = true
        }
    }

    /// Da chiamare con `indexLock` acquisito.
    func saveIndexLocked(_ model: VaultIndex) throws {

        let key = try makeKey()

        let encrypted = try VaultCrypto.encrypt(
            try model.serialized(),
            using: VaultCrypto.indexKey(masterKey: key)
        )

        let fileManager = FileManager.default

        // Copia di sicurezza della versione precedente (ma non se l'indice principale
        // era illeggibile: si perderebbe l'unica copia buona).
        if !indexLoadedFromBackup, fileManager.fileExists(atPath: indexURL.path) {

            try? fileManager.removeItem(at: indexBackupURL)
            try? fileManager.copyItem(at: indexURL, to: indexBackupURL)
        }

        try encrypted.write(
            to: indexURL,
            options: [.atomic, .completeFileProtection]
        )

        indexLoadedFromBackup = false
    }

    /// Lettura dell'indice (con il lock).
    private func withIndex<T>(
        _ body: (VaultIndex) throws -> T
    ) throws -> T {

        try requireUnlocked()

        indexLock.lock()
        defer { indexLock.unlock() }

        try loadIndexLocked()

        guard let current = index else {
            throw VaultStoreError.locked
        }

        return try body(current)
    }

    /// Modifica dell'indice: si lavora su una copia e la si salva (cifrata) prima
    /// di renderla attiva, così un errore non lascia l'indice a metà.
    private func mutateIndex<T>(
        _ body: (inout VaultIndex) throws -> T
    ) throws -> T {

        try requireUnlocked()

        indexLock.lock()
        defer { indexLock.unlock() }

        try loadIndexLocked()

        guard var copy = index else {
            throw VaultStoreError.locked
        }

        let result = try body(&copy)

        try saveIndexLocked(copy)

        index = copy

        return result
    }

    /// Imposta l'indice dopo la migrazione (con `indexLock` già acquisito).
    func adoptMigratedIndexLocked(_ model: VaultIndex) {

        index = model
        legacy = false
        indexLoadedFromBackup = false
    }

    // MARK: - Open

    /// Da chiamare subito dopo lo sblocco: carica (e quindi verifica) l'indice
    /// ed elimina i file orfani. Per i vault v0.2 non fa nulla.
    func prepare() throws {

        if isLegacy {
            return
        }

        _ = try withIndex { $0.nodes.count }

        try ensureContentDirectory()

        removeOrphans()
    }

    func ensureContentDirectory() throws {

        if !FileManager.default.fileExists(atPath: contentDirectory.path) {

            try FileManager.default.createDirectory(
                at: contentDirectory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
        }
    }

    /// Elimina da `files/` ciò che l'indice non conosce (import o eliminazioni
    /// interrotti, residui). Non si tocca nulla se l'indice è stato recuperato
    /// dalla copia di sicurezza: potrebbe essere indietro rispetto ai file.
    private func removeOrphans() {

        indexLock.lock()
        let fromBackup = indexLoadedFromBackup
        indexLock.unlock()

        guard !fromBackup else {
            return
        }

        guard let known = try? withIndex({ index in

            Set(
                index.nodes.values
                    .filter { !$0.isFolder }
                    .map { $0.id.uuidString + ".vltx" }
            )

        }) else {
            return
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: contentDirectory,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return
        }

        for entry in entries where !known.contains(entry.lastPathComponent) {
            try? SecureDelete.remove(at: entry)
        }
    }

    // MARK: - Listing

    func items(in directory: URL) throws -> [VaultItem] {

        let parent = try nodeID(for: directory)

        return try withIndex { index in

            try Self.requireFolder(parent, in: index)

            return index.children(of: parent).map { makeItem($0) }
        }
    }

    // MARK: - Folders

    @discardableResult
    func createFolder(
        named name: String,
        in directory: URL
    ) throws -> URL {

        let clean = try Self.validatedName(name)
        let parent = try nodeID(for: directory)

        return try mutateIndex { index in

            try Self.requireFolder(parent, in: index)

            guard !index.nameExists(clean, in: parent) else {
                throw VaultStoreError.itemAlreadyExists
            }

            let now = Date()

            let node = VaultNode(
                id: UUID(),
                parentID: parent,
                name: clean,
                isFolder: true,
                size: 0,
                created: now,
                modified: now
            )

            index.nodes[node.id] = node

            return url(for: node)
        }
    }

    // MARK: - Rename

    /// Rinominare cambia solo l'indice: i file su disco non si toccano.
    @discardableResult
    func renameItem(
        _ item: VaultItem,
        to newName: String
    ) throws -> URL {

        let clean = try Self.validatedName(newName)

        return try mutateIndex { index in

            guard let id = try nodeID(for: item.url),
                  var node = index.nodes[id]
            else {
                throw VaultStoreError.invalidLocation
            }

            if node.name == clean {
                return url(for: node)
            }

            guard !index.nameExists(clean, in: node.parentID, excluding: id) else {
                throw VaultStoreError.itemAlreadyExists
            }

            node.name = clean
            index.nodes[id] = node

            return url(for: node)
        }
    }

    // MARK: - Move

    private func canMove(
        _ item: VaultItem,
        to folder: URL,
        in index: VaultIndex
    ) throws -> Bool {

        guard let id = try nodeID(for: item.url),
              let node = index.nodes[id]
        else {
            return false
        }

        let target = try nodeID(for: folder)

        if let target {

            guard let targetNode = index.nodes[target], targetNode.isFolder else {
                return false
            }
        }

        // Già nella cartella di destinazione.
        if node.parentID == target {
            return false
        }

        // Una cartella non può finire dentro se stessa o in un suo discendente.
        if node.isFolder, let target {

            if target == id || index.isDescendant(target, of: id) {
                return false
            }
        }

        return true
    }

    func canMove(
        _ item: VaultItem,
        to folder: URL
    ) -> Bool {

        (try? withIndex { index in
            try canMove(item, to: folder, in: index)
        }) ?? false
    }

    /// Quanti degli elementi possono essere spostati nella cartella indicata.
    func movableCount(
        _ items: [VaultItem],
        to folder: URL
    ) -> Int {

        items.filter { canMove($0, to: folder) }.count
    }

    @discardableResult
    func moveItem(
        _ item: VaultItem,
        to folder: URL
    ) throws -> URL {

        try mutateIndex { index in

            guard try canMove(item, to: folder, in: index) else {
                throw VaultStoreError.invalidMove
            }

            guard let id = try nodeID(for: item.url),
                  var node = index.nodes[id]
            else {
                throw VaultStoreError.invalidLocation
            }

            let target = try nodeID(for: folder)

            node.name = index.uniqueName(
                for: node.name,
                isFolder: node.isFolder,
                in: target
            )

            node.parentID = target

            index.nodes[id] = node

            return url(for: node)
        }
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

        let selected = Set(items.compactMap { try? nodeID(for: $0.url) })

        let result = try? withIndex { index in

            items.filter { item in

                guard let id = try? nodeID(for: item.url) else {
                    return true
                }

                return !selected.contains { ancestor in
                    index.isDescendant(id, of: ancestor)
                }
            }
        }

        return result ?? items
    }

    // MARK: - Delete

    /// Elimina un file o una cartella (con tutto il contenuto). Prima si aggiorna
    /// l'indice, poi i file cifrati vengono sovrascritti con dati casuali (best
    /// effort) e rimossi. Se qualcosa si interrompe, i residui vengono ripuliti
    /// al prossimo sblocco.
    func deleteItem(_ item: VaultItem) throws {

        let removedFiles: [UUID] = try mutateIndex { index in

            guard let id = try nodeID(for: item.url),
                  index.nodes[id] != nil
            else {
                throw VaultStoreError.invalidLocation
            }

            var files: [UUID] = []

            for current in index.subtree(of: id) {

                if let node = index.nodes[current], !node.isFolder {
                    files.append(current)
                }

                index.nodes[current] = nil
            }

            return files
        }

        for id in removedFiles {
            try? SecureDelete.remove(at: fileURL(for: id))
        }
    }

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

    // MARK: - Import

    @discardableResult
    func importFile(
        at sourceURL: URL,
        into directory: URL
    ) throws -> URL {

        try requireUnlocked()

        let parent = try nodeID(for: directory)

        try withIndex { index in
            try Self.requireFolder(parent, in: index)
        }

        let key = try makeKey()

        try ensureContentDirectory()

        let id = UUID()
        let finalURL = fileURL(for: id)
        let partURL = finalURL.appendingPathExtension("part")

        let accessed = sourceURL.startAccessingSecurityScopedResource()

        defer {
            if accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let modified = (
            try? sourceURL.resourceValues(forKeys: [.contentModificationDateKey])
        )?.contentModificationDate ?? Date()

        let proposedName = Self.sanitizedImportName(sourceURL.lastPathComponent)

        let fileManager = FileManager.default

        // Cifratura a blocchi: la memoria usata non dipende dalla dimensione del file.
        let size: Int64

        do {

            size = try VaultCrypto.encryptFile(
                from: sourceURL,
                to: partURL,
                fileID: id,
                masterKey: key
            )

            try fileManager.moveItem(at: partURL, to: finalURL)

        } catch {

            try? fileManager.removeItem(at: partURL)
            try? fileManager.removeItem(at: finalURL)

            throw error
        }

        do {

            try mutateIndex { index in

                try Self.requireFolder(parent, in: index)

                let name = index.uniqueName(
                    for: proposedName,
                    isFolder: false,
                    in: parent
                )

                index.nodes[id] = VaultNode(
                    id: id,
                    parentID: parent,
                    name: name,
                    isFolder: false,
                    size: size,
                    created: Date(),
                    modified: modified
                )
            }

        } catch {

            try? fileManager.removeItem(at: finalURL)

            throw error
        }

        return finalURL
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

        let (id, name): (UUID, String) = try withIndex { index in

            guard let id = try nodeID(for: encryptedURL),
                  let node = index.nodes[id],
                  !node.isFolder
            else {
                throw VaultStoreError.invalidLocation
            }

            return (id, node.name)
        }

        let key = try makeKey()

        let directory = Self.openDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )

        let destination = directory.appendingPathComponent(name)

        try VaultCrypto.decryptFile(
            from: fileURL(for: id),
            to: destination,
            fileID: id,
            masterKey: key
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

        let limit = 25 * 1024 * 1024

        guard Self.supportsThumbnail(item),
              item.size <= Int64(limit)
        else {
            return nil
        }

        let cacheKey = "\(item.url.path)|\(item.modified?.timeIntervalSince1970 ?? 0)" as NSString

        if let cached = thumbnailCache.object(forKey: cacheKey) {
            return cached
        }

        guard let key = try? makeKey(),
              let id = try? nodeID(for: item.url),
              let clear = try? VaultCrypto.decryptToData(
                from: fileURL(for: id),
                fileID: id,
                masterKey: key,
                maximumSize: limit
              )
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

// MARK: - Migration from the v0.2 format

extension VaultSession {

    /// Converte un vault v0.2 (nomi in chiaro, file cifrati interi) nel formato v3:
    /// nomi e cartelle finiscono nell'indice cifrato, i file vengono ricifrati
    /// a blocchi con chiavi per file.
    ///
    /// Il vecchio albero (`data/`) resta intatto finché l'indice nuovo non è stato
    /// scritto: se qualcosa va storto (errore, crash, batteria) il vault resta
    /// utilizzabile nel vecchio formato e si può riprovare.
    func migrateFromLegacy(
        progress: ((Int, Int) -> Void)? = nil
    ) throws {

        try requireUnlocked()

        guard isLegacy else {
            return
        }

        let key = try makeKey()
        let fileManager = FileManager.default

        let total = Self.countLegacyFiles(in: legacyDataDirectory)

        // Residui di un tentativo precedente interrotto.
        try? fileManager.removeItem(at: contentDirectory)

        try fileManager.createDirectory(
            at: contentDirectory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )

        var model = VaultIndex()
        var done = 0

        progress?(0, total)

        do {

            try migrateDirectory(
                legacyDataDirectory,
                parent: nil,
                model: &model,
                key: key,
                done: &done,
                total: total,
                progress: progress
            )

        } catch {

            try? fileManager.removeItem(at: contentDirectory)

            throw error
        }

        // L'indice si scrive per ultimo: da questo momento il vault è v3.
        indexLock.lock()
        defer { indexLock.unlock() }

        do {

            try saveIndexLocked(model)

        } catch {

            try? fileManager.removeItem(at: contentDirectory)

            throw error
        }

        adoptMigratedIndexLocked(model)

        // Manifest aggiornato e rimozione del vecchio albero (nomi in chiaro).
        try? writeManifest(version: 3, key: key)

        try? fileManager.removeItem(at: legacyDataDirectory)
    }

    private func writeManifest(
        version: Int,
        key: SymmetricKey
    ) throws {

        let updated = VaultManifest(
            version: version,
            name: manifest.name,
            createdAt: manifest.createdAt
        )

        let encrypted = try VaultCrypto.encrypt(
            try JSONEncoder().encode(updated),
            using: key
        )

        try encrypted.write(
            to: vaultURL.appendingPathComponent("vault.manifest"),
            options: [.atomic, .completeFileProtection]
        )
    }

    private static func countLegacyFiles(in directory: URL) -> Int {

        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return 0
        }

        var count = 0

        for case let url as URL in enumerator
        where url.pathExtension.lowercased() == "vltx" {
            count += 1
        }

        return count
    }

    private func migrateDirectory(
        _ directory: URL,
        parent: UUID?,
        model: inout VaultIndex,
        key: SymmetricKey,
        done: inout Int,
        total: Int,
        progress: ((Int, Int) -> Void)?
    ) throws {

        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .contentModificationDateKey
        ]

        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: []
        )
        .sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                == .orderedAscending
        }

        for entry in entries {

            let values = try? entry.resourceValues(forKeys: Set(keys))
            let modified = values?.contentModificationDate ?? Date()

            if values?.isDirectory == true {

                let folder = VaultNode(
                    id: UUID(),
                    parentID: parent,
                    name: entry.lastPathComponent,
                    isFolder: true,
                    size: 0,
                    created: modified,
                    modified: modified
                )

                model.nodes[folder.id] = folder

                try migrateDirectory(
                    entry,
                    parent: folder.id,
                    model: &model,
                    key: key,
                    done: &done,
                    total: total,
                    progress: progress
                )

            } else if entry.pathExtension.lowercased() == "vltx" {

                let id = UUID()
                let name = Self.originalName(of: entry)

                do {

                    let encrypted = try Data(contentsOf: entry, options: .mappedIfSafe)

                    let plain = try VaultCrypto.decrypt(encrypted, using: key)

                    let size = try VaultCrypto.encryptData(
                        plain,
                        to: fileURL(for: id),
                        fileID: id,
                        masterKey: key
                    )

                    model.nodes[id] = VaultNode(
                        id: id,
                        parentID: parent,
                        name: name,
                        isFolder: false,
                        size: size,
                        created: modified,
                        modified: modified
                    )

                } catch {

                    throw VaultStoreError.migrationFailed(
                        "\(name): \(error.localizedDescription)"
                    )
                }

                done += 1

                progress?(done, total)
            }
        }
    }
}
