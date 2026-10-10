import Foundation
import CryptoKit

enum VaultPackageError: LocalizedError {

    case notAPackage
    case unsupportedVersion
    case corrupted(String)
    case unsafePath(String)
    case invalidVault

    var errorDescription: String? {

        switch self {

        case .notAPackage:
            return "Il file non è un pacchetto vault di VaultX."

        case .unsupportedVersion:
            return "Il pacchetto è stato creato da una versione di VaultX più recente."

        case .corrupted(let detail):
            return "Il pacchetto è danneggiato o è stato alterato (\(detail))."

        case .unsafePath(let path):
            return "Il pacchetto contiene un percorso non valido: \(path)"

        case .invalidVault:
            return "Il pacchetto non contiene un vault completo."
        }
    }
}

/// Pacchetto di esportazione di un vault (`.vaultxpkg`, formato "VXVAULT1").
///
/// Il vault è già interamente cifrato su disco, quindi il pacchetto è semplicemente il suo
/// contenuto impacchettato in un unico file in streaming (memoria costante), con un
/// SHA-256 per ogni file e un riepilogo finale che rivelano corruzioni o manomissioni.
/// Il pacchetto si apre con la stessa password del vault (le chiavi Face ID non vengono esportate).
///
///     "VXVAULT1" (8) | headerLength UInt32 BE | header JSON {format, name, createdAt}
///     entry*  : 0x01 | pathLength UInt16 BE | path UTF-8 | size UInt64 BE | data | digest (32)
///               digest = SHA-256(path UTF-8 | size UInt64 BE | data)
///     fine    : 0x00 | entryCount UInt32 BE | SHA-256(concatenazione dei digest delle entry) (32)
enum VaultPackage {

    static let fileExtension = "vaultxpkg"

    private static let magic = Data("VXVAULT1".utf8)
    private static let bufferSize = 1 << 20
    private static let maxEntries = 2_000_000

    /// Nel pacchetto entrano solo questi elementi della cartella del vault.
    private static let allowedRoots: Set<String> = [
        "masterkey.vaultx", "recovery.vaultx", "vault.manifest",
        "index.vaultx", "index.vaultx.bak", "profile.json",
        "files", "data"
    ]

    struct Header: Codable {
        var format: Int
        var name: String
        var createdAt: Date
    }

    // MARK: - Byte helpers

    private static func bytes<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private static func integer(_ data: Data) -> UInt64 {
        data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private static func readExactly(
        _ handle: FileHandle,
        _ count: Int
    ) throws -> Data {

        var result = Data()

        while result.count < count {

            let piece = try handle.read(upToCount: count - result.count) ?? Data()

            if piece.isEmpty {
                throw VaultPackageError.corrupted("file troncato")
            }

            result.append(piece)
        }

        return result
    }

    // MARK: - Export

    private struct Entry {
        let path: String
        let url: URL
        let size: Int64
    }

    private static func collect(
        _ directory: URL,
        prefix: String,
        into entries: inout [Entry]
    ) throws {

        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]

        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: []
        )

        for url in children {

            let name = url.lastPathComponent

            // Al livello radice solo gli elementi previsti dal formato del vault.
            if prefix.isEmpty, !allowedRoots.contains(name) {
                continue
            }

            let values = try url.resourceValues(forKeys: Set(keys))

            if values.isSymbolicLink == true {
                continue
            }

            if values.isDirectory == true {

                try collect(url, prefix: prefix + name + "/", into: &entries)

            } else if values.isRegularFile == true {

                // Residui di operazioni interrotte.
                if name.hasSuffix(".part") {
                    continue
                }

                entries.append(
                    Entry(
                        path: prefix + name,
                        url: url,
                        size: Int64(values.fileSize ?? 0)
                    )
                )
            }
        }
    }

    /// Crea il pacchetto `destination` a partire dalla cartella del vault.
    /// `progress` riceve (byte scritti, byte totali).
    static func export(
        vaultURL: URL,
        to destination: URL,
        progress: ((Int64, Int64) -> Void)? = nil
    ) throws {

        var entries: [Entry] = []

        try collect(vaultURL, prefix: "", into: &entries)

        entries.sort { $0.path < $1.path }

        guard entries.contains(where: { $0.path == "masterkey.vaultx" }),
              entries.contains(where: { $0.path == "vault.manifest" })
        else {
            throw VaultPackageError.invalidVault
        }

        guard FileManager.default.createFile(
            atPath: destination.path,
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.complete]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let output = try FileHandle(forWritingTo: destination)

        defer {
            try? output.close()
        }

        do {

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601

            let headerJSON = try encoder.encode(
                Header(
                    format: 1,
                    name: vaultURL.lastPathComponent,
                    createdAt: Date()
                )
            )

            try output.write(contentsOf: magic)
            try output.write(contentsOf: bytes(UInt32(headerJSON.count)))
            try output.write(contentsOf: headerJSON)

            let total = entries.reduce(Int64(0)) { $0 + $1.size }
            var done: Int64 = 0

            var overall = SHA256()

            for entry in entries {

                let pathBytes = Data(entry.path.utf8)

                guard pathBytes.count <= 1024 else {
                    throw VaultPackageError.unsafePath(entry.path)
                }

                let sizeBytes = bytes(UInt64(entry.size))

                var head = Data([0x01])
                head.append(bytes(UInt16(pathBytes.count)))
                head.append(pathBytes)
                head.append(sizeBytes)

                try output.write(contentsOf: head)

                let input = try FileHandle(forReadingFrom: entry.url)

                defer {
                    try? input.close()
                }

                var hasher = SHA256()
                hasher.update(data: pathBytes)
                hasher.update(data: sizeBytes)

                var remaining = entry.size

                while remaining > 0 {

                    let chunk = try input.read(
                        upToCount: Int(min(Int64(bufferSize), remaining))
                    ) ?? Data()

                    guard !chunk.isEmpty else {
                        throw VaultPackageError.corrupted(
                            "un file è cambiato durante l'esportazione"
                        )
                    }

                    hasher.update(data: chunk)
                    try output.write(contentsOf: chunk)

                    remaining -= Int64(chunk.count)
                    done += Int64(chunk.count)

                    progress?(done, total)
                }

                let digest = Data(hasher.finalize())

                try output.write(contentsOf: digest)

                overall.update(data: digest)
            }

            var end = Data([0x00])
            end.append(bytes(UInt32(entries.count)))
            end.append(Data(overall.finalize()))

            try output.write(contentsOf: end)
            try output.synchronize()

        } catch {

            try? FileManager.default.removeItem(at: destination)

            throw error
        }
    }

    // MARK: - Inspect

    /// Legge solo l'intestazione (nome del vault) senza importare nulla.
    static func inspect(_ source: URL) throws -> Header {

        let accessed = source.startAccessingSecurityScopedResource()

        defer {
            if accessed {
                source.stopAccessingSecurityScopedResource()
            }
        }

        let input = try FileHandle(forReadingFrom: source)

        defer {
            try? input.close()
        }

        return try readHeader(from: input).header
    }

    private static func readHeader(
        from input: FileHandle
    ) throws -> (header: Header, length: Int) {

        guard let start = try? readExactly(input, magic.count),
              start == magic
        else {
            throw VaultPackageError.notAPackage
        }

        let length = Int(integer(try readExactly(input, 4)))

        guard length > 0, length <= 65_536 else {
            throw VaultPackageError.notAPackage
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let header = try? decoder.decode(
            Header.self,
            from: try readExactly(input, length)
        ) else {
            throw VaultPackageError.notAPackage
        }

        guard header.format == 1 else {
            throw VaultPackageError.unsupportedVersion
        }

        return (header, magic.count + 4 + length)
    }

    // MARK: - Import

    private static func safeDestination(
        for path: String,
        in root: URL
    ) throws -> URL {

        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("\0")
        else {
            throw VaultPackageError.unsafePath(path)
        }

        let components = path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)

        guard let first = components.first,
              allowedRoots.contains(first),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw VaultPackageError.unsafePath(path)
        }

        var url = root

        for (index, component) in components.enumerated() {

            url.appendPathComponent(
                component,
                isDirectory: index < components.count - 1
            )
        }

        return url
    }

    private static func sanitizedFolderName(_ raw: String) -> String {

        let invalid = CharacterSet(charactersIn: "/\\:\0")

        let cleaned = raw
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.isEmpty || cleaned.hasPrefix(".") {
            return "Vault"
        }

        return cleaned
    }

    private static func uniqueFolder(
        named base: String,
        in root: URL
    ) -> URL {

        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var counter = 2

        while FileManager.default.fileExists(atPath: candidate.path) {

            candidate = root.appendingPathComponent(
                "\(base) (\(counter))",
                isDirectory: true
            )

            counter += 1
        }

        return candidate
    }

    /// Importa un pacchetto creando un nuovo vault in `rootURL` (mai sovrascrive un vault
    /// esistente: in caso di nome già usato aggiunge " (2)", " (3)"...). Ogni file viene
    /// verificato con il suo SHA-256; il vault diventa visibile solo a importazione completata.
    @discardableResult
    static func importPackage(
        from source: URL,
        into rootURL: URL,
        preferredName: String? = nil,
        progress: ((Int64, Int64) -> Void)? = nil
    ) throws -> URL {

        let fileManager = FileManager.default

        let accessed = source.startAccessingSecurityScopedResource()

        defer {
            if accessed {
                source.stopAccessingSecurityScopedResource()
            }
        }

        let input = try FileHandle(forReadingFrom: source)

        defer {
            try? input.close()
        }

        let totalSize = (
            (try? fileManager.attributesOfItem(atPath: source.path))?[.size] as? NSNumber
        )?.int64Value ?? 0

        let (header, headerLength) = try readHeader(from: input)

        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )

        // Cartella nascosta: finché non è completa non compare nell'elenco dei vault.
        let staging = rootURL.appendingPathComponent(
            ".import-\(UUID().uuidString)",
            isDirectory: true
        )

        try fileManager.createDirectory(
            at: staging,
            withIntermediateDirectories: true
        )

        var completed = false

        defer {
            if !completed {
                try? fileManager.removeItem(at: staging)
            }
        }

        var overall = SHA256()
        var count = 0
        var consumed = Int64(headerLength)
        var seen = Set<String>()

        while true {

            let marker = try readExactly(input, 1)

            if marker[marker.startIndex] == 0x00 {

                let declared = Int(integer(try readExactly(input, 4)))
                let digest = try readExactly(input, 32)

                guard declared == count,
                      digest == Data(overall.finalize())
                else {
                    throw VaultPackageError.corrupted("riepilogo finale non valido")
                }

                break
            }

            guard marker[marker.startIndex] == 0x01 else {
                throw VaultPackageError.corrupted("struttura non valida")
            }

            count += 1

            guard count <= maxEntries else {
                throw VaultPackageError.corrupted("troppi file")
            }

            let pathLength = Int(integer(try readExactly(input, 2)))

            let pathData = try readExactly(input, pathLength)

            guard pathLength > 0, pathLength <= 1024,
                  let path = String(data: pathData, encoding: .utf8)
            else {
                throw VaultPackageError.corrupted("percorso non valido")
            }

            guard seen.insert(path).inserted else {
                throw VaultPackageError.corrupted("file duplicato")
            }

            let sizeData = try readExactly(input, 8)
            let declaredSize = integer(sizeData)

            guard declaredSize <= UInt64(1) << 42 else {
                throw VaultPackageError.corrupted("dimensione non valida")
            }

            let destination = try safeDestination(for: path, in: staging)

            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            guard fileManager.createFile(
                atPath: destination.path,
                contents: nil,
                attributes: [.protectionKey: FileProtectionType.complete]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }

            let output = try FileHandle(forWritingTo: destination)

            var hasher = SHA256()
            hasher.update(data: pathData)
            hasher.update(data: sizeData)

            var remaining = Int64(declaredSize)

            do {

                while remaining > 0 {

                    let chunk = try input.read(
                        upToCount: Int(min(Int64(bufferSize), remaining))
                    ) ?? Data()

                    guard !chunk.isEmpty else {
                        throw VaultPackageError.corrupted("file troncato")
                    }

                    hasher.update(data: chunk)
                    try output.write(contentsOf: chunk)

                    remaining -= Int64(chunk.count)
                    consumed += Int64(chunk.count)

                    progress?(consumed, totalSize)
                }

                try output.close()

            } catch {

                try? output.close()

                throw error
            }

            let computed = Data(hasher.finalize())
            let stored = try readExactly(input, 32)

            guard computed == stored else {
                throw VaultPackageError.corrupted("controllo di integrità fallito")
            }

            overall.update(data: computed)

            consumed += Int64(1 + 2 + pathLength + 8 + 32)
        }

        // Deve essere un vault completo.
        func exists(_ name: String) -> Bool {
            fileManager.fileExists(
                atPath: staging.appendingPathComponent(name).path
            )
        }

        guard exists("masterkey.vaultx"),
              exists("vault.manifest"),
              exists("index.vaultx") || exists("data")
        else {
            throw VaultPackageError.invalidVault
        }

        let name = sanitizedFolderName(preferredName ?? header.name)

        let finalURL = uniqueFolder(named: name, in: rootURL)

        try fileManager.moveItem(at: staging, to: finalURL)

        completed = true

        progress?(totalSize, totalSize)

        return finalURL
    }
}
