import Foundation
import CryptoKit

enum SharePackageError: LocalizedError {

    case notAPackage
    case expired(Date)
    case wrongPasswordOrCorrupted
    case invalidMetadata

    var errorDescription: String? {

        switch self {

        case .notAPackage:
            return "Il file non è un pacchetto protetto di VaultX."

        case .expired(let date):
            return "Il pacchetto è scaduto il \(date.formatted(date: .long, time: .shortened))."

        case .wrongPasswordOrCorrupted:
            return "Password errata o pacchetto danneggiato."

        case .invalidMetadata:
            return "Il pacchetto contiene dati non validi."
        }
    }
}

/// Pacchetto protetto da password per condividere un singolo file (`.vaultxshare`).
///
///     header (51 byte, autenticato come AAD di ogni chunk):
///       "VXSHR1" (6) | chunkSizeLog2 (1) | iterazioni UInt32 BE (4) | salt PBKDF2 (16)
///       | ID pacchetto (16) | scadenza Int64 BE, secondi dal 1970, 0 = nessuna (8)
///     corpo: chunk AES-256-GCM (stesso schema dei file del vault) di questo flusso in chiaro:
///       metadataLength UInt32 BE | metadata JSON {name, size, createdAt} | contenuto del file
///
/// Chiave: PBKDF2-HMAC-SHA256(password normalizzata, salt, iterazioni) poi HKDF "VaultX share key v1".
/// Il nome del file è cifrato nel corpo. La scadenza è nell'header autenticato: non si può
/// modificare senza invalidare il pacchetto, ma viene fatta rispettare solo da VaultX
/// all'apertura e non può cancellare copie già ricevute.
enum SharePackage {

    static let fileExtension = "vaultxshare"

    private static let magic = Data("VXSHR1".utf8)
    static let headerLength = 6 + 1 + 4 + 16 + 16 + 8
    private static let keyInfo = Data("VaultX share key v1".utf8)

    struct Metadata: Codable {
        var name: String
        var size: Int64
        var createdAt: Date
    }

    struct Info {
        var expiresAt: Date?

        var isExpired: Bool {
            guard let expiresAt else { return false }
            return Date() > expiresAt
        }
    }

    // MARK: - Helpers

    private static func bytes<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private static func integer(_ bytes: [UInt8]) -> UInt64 {
        bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private static func safeName(_ raw: String) -> String {

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

    private static func key(
        password: String,
        salt: Data,
        iterations: UInt32
    ) throws -> SymmetricKey {

        let passwordKey = try VaultCrypto.deriveKey(
            password: VaultCrypto.normalized(password),
            salt: salt,
            iterations: iterations
        )

        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: passwordKey,
            salt: Data(),
            info: keyInfo,
            outputByteCount: VaultCrypto.keyLength
        )
    }

    // MARK: - Create

    /// Cifra `source` in un pacchetto protetto da `password`.
    static func create(
        from source: URL,
        name: String,
        password: String,
        expiresAt: Date?,
        to destination: URL
    ) throws {

        let chunkLog2 = VaultFileFormat.defaultChunkSizeLog2
        let chunkSize = 1 << Int(chunkLog2)

        let salt = try VaultCrypto.randomBytes(count: VaultCrypto.saltLength)
        let iterations = VaultCrypto.wrapIterations

        var header = magic
        header.append(chunkLog2)
        header.append(bytes(iterations))
        header.append(salt)
        header.append(withUnsafeBytes(of: UUID().uuid) { Data($0) })

        let expiry = expiresAt.map { Int64($0.timeIntervalSince1970) } ?? 0
        header.append(bytes(UInt64(bitPattern: expiry)))

        precondition(header.count == headerLength)

        let packageKey = try key(password: password, salt: salt, iterations: iterations)

        let size = (
            (try? FileManager.default.attributesOfItem(atPath: source.path))?[.size] as? NSNumber
        )?.int64Value ?? 0

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let metadataJSON = try encoder.encode(
            Metadata(name: safeName(name), size: size, createdAt: Date())
        )

        var pending = bytes(UInt32(metadataJSON.count))
        pending.append(metadataJSON)

        let input = try FileHandle(forReadingFrom: source)

        defer {
            try? input.close()
        }

        var sourceFinished = false

        _ = try VaultCrypto.writeChunks(
            next: {

                // Si riempie sempre un chunk intero: tutti tranne l'ultimo devono esserlo.
                while pending.count < chunkSize, !sourceFinished {

                    let piece = try input.read(upToCount: chunkSize) ?? Data()

                    if piece.isEmpty {
                        sourceFinished = true
                    } else {
                        pending.append(piece)
                    }
                }

                let take = min(chunkSize, pending.count)
                let chunk = Data(pending.prefix(take))

                pending.removeFirst(take)

                return chunk
            },
            to: destination,
            header: header,
            key: packageKey,
            aad: header
        )
    }

    // MARK: - Inspect / Open

    private static func readHeader(
        from input: FileHandle
    ) throws -> (raw: Data, log2: UInt8, iterations: UInt32, salt: Data, expiresAt: Date?) {

        let raw = try input.read(upToCount: headerLength) ?? Data()

        guard raw.count == headerLength,
              Data(raw.prefix(magic.count)) == magic
        else {
            throw SharePackageError.notAPackage
        }

        let array = Array(raw)

        let log2 = array[6]

        guard log2 >= VaultFileFormat.minChunkSizeLog2,
              log2 <= VaultFileFormat.maxChunkSizeLog2
        else {
            throw SharePackageError.notAPackage
        }

        let iterations = UInt32(integer(Array(array[7 ..< 11])))

        guard iterations >= 100_000, iterations <= 10_000_000 else {
            throw SharePackageError.notAPackage
        }

        let salt = Data(array[11 ..< 27])

        let expiry = Int64(bitPattern: integer(Array(array[43 ..< 51])))

        return (
            raw,
            log2,
            iterations,
            salt,
            expiry == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(expiry))
        )
    }

    /// Legge solo l'intestazione: serve a mostrare la scadenza prima di chiedere la password.
    static func inspect(_ url: URL) throws -> Info {

        let accessed = url.startAccessingSecurityScopedResource()

        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let input = try FileHandle(forReadingFrom: url)

        defer {
            try? input.close()
        }

        return Info(expiresAt: try readHeader(from: input).expiresAt)
    }

    /// Decifra il pacchetto in `VaultXOpen/<uuid>/<nome originale>` e restituisce metadati e URL.
    static func open(
        _ url: URL,
        password: String
    ) throws -> (metadata: Metadata, fileURL: URL) {

        let accessed = url.startAccessingSecurityScopedResource()

        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let input = try FileHandle(forReadingFrom: url)

        defer {
            try? input.close()
        }

        let header = try readHeader(from: input)

        if let expiresAt = header.expiresAt, Date() > expiresAt {
            throw SharePackageError.expired(expiresAt)
        }

        let packageKey = try key(
            password: password,
            salt: header.salt,
            iterations: header.iterations
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let directory = VaultSession.openDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )

        var buffer = Data()
        var parsedMetadata: Metadata?
        var output: FileHandle?
        var outputFileURL: URL?

        func cleanup() {

            try? output?.close()
            output = nil

            try? FileManager.default.removeItem(at: directory)
        }

        do {

            try VaultCrypto.readChunks(
                from: input,
                key: packageKey,
                aad: header.raw,
                cipherChunkSize: (1 << Int(header.log2)) + VaultFileFormat.tagLength
            ) { chunk in

                if let handle = output {

                    try handle.write(contentsOf: chunk)
                    return
                }

                buffer.append(chunk)

                guard buffer.count >= 4 else {
                    return
                }

                let length = Int(integer(Array(buffer.prefix(4))))

                guard length > 0, length <= 1 << 20 else {
                    throw SharePackageError.invalidMetadata
                }

                guard buffer.count >= 4 + length else {
                    return
                }

                guard let decoded = try? decoder.decode(
                    Metadata.self,
                    from: Data(buffer[buffer.startIndex + 4 ..< buffer.startIndex + 4 + length])
                ) else {
                    throw SharePackageError.invalidMetadata
                }

                parsedMetadata = decoded

                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.complete]
                )

                let destination = directory.appendingPathComponent(safeName(decoded.name))

                guard FileManager.default.createFile(
                    atPath: destination.path,
                    contents: nil,
                    attributes: [.protectionKey: FileProtectionType.complete]
                ) else {
                    throw CocoaError(.fileWriteUnknown)
                }

                let handle = try FileHandle(forWritingTo: destination)

                output = handle
                outputFileURL = destination

                let rest = Data(buffer.dropFirst(4 + length))

                if !rest.isEmpty {
                    try handle.write(contentsOf: rest)
                }

                buffer = Data()
            }

            try output?.synchronize()
            try output?.close()
            output = nil

        } catch VaultCryptoError.authenticationFailed {

            cleanup()

            throw SharePackageError.wrongPasswordOrCorrupted

        } catch {

            cleanup()

            throw error
        }

        guard let finalMetadata = parsedMetadata,
              let finalURL = outputFileURL
        else {

            cleanup()

            throw SharePackageError.invalidMetadata
        }

        return (finalMetadata, finalURL)
    }
}
