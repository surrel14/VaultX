import Foundation
import CryptoKit

// MARK: - Format constants

/// File del vault v3 ("VLTX03"): cifratura a blocchi con AES-256-GCM.
///
///     [magic "VLTX03" 6][chunkSizeLog2 1][salt 32]            <- header, 39 byte
///     [chunk 0: ciphertext + tag 16] [chunk 1: ...] ... [ultimo chunk]
///
/// - Chiave del file: HKDF-SHA256(ikm: master key, salt: salt del file, info: "VaultX v3 file key").
///   Ogni file ha quindi una chiave diversa.
/// - Nonce del chunk i (12 byte): 7 byte a zero || i (UInt32 big endian) || flag (1 = ultimo chunk).
///   Il flag impedisce il troncamento; il contatore impedisce di riordinare i chunk.
/// - AAD di ogni chunk: header || fileID (16 byte). Il file è legato al suo ID: scambiare
///   due file su disco ne fa fallire l'apertura.
/// - Tutti i chunk tranne l'ultimo hanno la dimensione piena (2^chunkSizeLog2 byte di dati);
///   l'ultimo ne ha da 1 a 2^chunkSizeLog2 (zero solo per un file vuoto).
enum VaultFileFormat {

    static let magic = Data("VLTX03".utf8)

    static let defaultChunkSizeLog2: UInt8 = 16        // 64 KiB
    static let minChunkSizeLog2: UInt8 = 10
    static let maxChunkSizeLog2: UInt8 = 24

    static let saltLength = 32
    static let tagLength = 16
    static let headerLength = 6 + 1 + saltLength        // 39

    static let fileKeyInfo = Data("VaultX v3 file key".utf8)
    static let indexKeyInfo = Data("VaultX v3 index key".utf8)
}

// MARK: - Streaming file encryption

extension VaultCrypto {

    // MARK: Keys

    static func fileKey(masterKey: SymmetricKey, salt: Data) -> SymmetricKey {

        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            salt: salt,
            info: VaultFileFormat.fileKeyInfo,
            outputByteCount: keyLength
        )
    }

    /// Chiave dell'indice cifrato (nomi, cartelle, struttura).
    static func indexKey(masterKey: SymmetricKey) -> SymmetricKey {

        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            salt: Data(),
            info: VaultFileFormat.indexKeyInfo,
            outputByteCount: keyLength
        )
    }

    // MARK: Helpers

    private static func chunkNonce(
        counter: UInt32,
        isLast: Bool
    ) throws -> AES.GCM.Nonce {

        var bytes = [UInt8](repeating: 0, count: 7)

        bytes.append(contentsOf: withUnsafeBytes(of: counter.bigEndian) { Array($0) })
        bytes.append(isLast ? 1 : 0)

        return try AES.GCM.Nonce(data: Data(bytes))
    }

    private static func idBytes(_ fileID: UUID) -> Data {
        withUnsafeBytes(of: fileID.uuid) { Data($0) }
    }

    /// Dimensione in chiaro di un file v3 a partire dalla dimensione su disco.
    static func plaintextSize(
        forEncryptedSize size: Int64,
        chunkSizeLog2: UInt8 = VaultFileFormat.defaultChunkSizeLog2
    ) -> Int64? {

        let body = size - Int64(VaultFileFormat.headerLength)

        guard body >= Int64(VaultFileFormat.tagLength) else {
            return nil
        }

        let cipherChunk = (Int64(1) << Int64(chunkSizeLog2)) + Int64(VaultFileFormat.tagLength)
        let chunks = (body + cipherChunk - 1) / cipherChunk

        return body - chunks * Int64(VaultFileFormat.tagLength)
    }

    // MARK: Encrypt

    /// `next` restituisce il blocco di dati successivo (al massimo 2^chunkSizeLog2 byte)
    /// e un `Data` vuoto a fine contenuto. Restituisce la dimensione in chiaro.
    private static func encryptChunks(
        next: () throws -> Data,
        to destination: URL,
        fileID: UUID,
        masterKey: SymmetricKey,
        chunkSizeLog2: UInt8
    ) throws -> Int64 {

        let salt = try randomBytes(count: VaultFileFormat.saltLength)

        var header = VaultFileFormat.magic
        header.append(chunkSizeLog2)
        header.append(salt)

        let aad = header + idBytes(fileID)
        let key = fileKey(masterKey: masterKey, salt: salt)

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

        try output.write(contentsOf: header)

        var total: Int64 = 0
        var counter: UInt32 = 0

        var current = try next()

        while true {

            // Si guarda avanti di un blocco: serve a sapere se `current` è l'ultimo.
            let following = try next()
            let isLast = following.isEmpty

            let sealed = try AES.GCM.seal(
                current,
                using: key,
                nonce: try chunkNonce(counter: counter, isLast: isLast),
                authenticating: aad
            )

            try output.write(contentsOf: sealed.ciphertext)
            try output.write(contentsOf: sealed.tag)

            total += Int64(current.count)

            if isLast {
                break
            }

            guard counter < UInt32.max else {
                throw VaultCryptoError.invalidFile
            }

            counter += 1
            current = following
        }

        try output.synchronize()

        return total
    }

    /// Cifra un file leggendolo a blocchi (memoria costante, anche per file enormi).
    static func encryptFile(
        from source: URL,
        to destination: URL,
        fileID: UUID,
        masterKey: SymmetricKey
    ) throws -> Int64 {

        let input = try FileHandle(forReadingFrom: source)

        defer {
            try? input.close()
        }

        let chunkSize = 1 << Int(VaultFileFormat.defaultChunkSizeLog2)

        return try encryptChunks(
            next: { try input.read(upToCount: chunkSize) ?? Data() },
            to: destination,
            fileID: fileID,
            masterKey: masterKey,
            chunkSizeLog2: VaultFileFormat.defaultChunkSizeLog2
        )
    }

    /// Cifra dati già in memoria (usato dalla migrazione e dai test).
    static func encryptData(
        _ data: Data,
        to destination: URL,
        fileID: UUID,
        masterKey: SymmetricKey,
        chunkSizeLog2: UInt8 = VaultFileFormat.defaultChunkSizeLog2
    ) throws -> Int64 {

        let chunkSize = 1 << Int(chunkSizeLog2)

        var offset = data.startIndex

        return try encryptChunks(
            next: {

                guard offset < data.endIndex else {
                    return Data()
                }

                let end = min(offset + chunkSize, data.endIndex)

                defer {
                    offset = end
                }

                return data.subdata(in: offset ..< end)
            },
            to: destination,
            fileID: fileID,
            masterKey: masterKey,
            chunkSizeLog2: chunkSizeLog2
        )
    }

    // MARK: Decrypt

    /// Decifra a blocchi e passa ogni blocco in chiaro a `sink`.
    /// Fallisce se un solo byte è stato modificato, se il file è troncato,
    /// riordinato o appartiene a un altro ID.
    static func decryptStream(
        from source: URL,
        fileID: UUID,
        masterKey: SymmetricKey,
        sink: (Data) throws -> Void
    ) throws {

        let input = try FileHandle(forReadingFrom: source)

        defer {
            try? input.close()
        }

        let header = try input.read(upToCount: VaultFileFormat.headerLength) ?? Data()

        guard header.count == VaultFileFormat.headerLength,
              Data(header.prefix(VaultFileFormat.magic.count)) == VaultFileFormat.magic
        else {
            throw VaultCryptoError.invalidFile
        }

        let log2 = header[header.startIndex + VaultFileFormat.magic.count]

        guard log2 >= VaultFileFormat.minChunkSizeLog2,
              log2 <= VaultFileFormat.maxChunkSizeLog2
        else {
            throw VaultCryptoError.invalidFile
        }

        let cipherChunkSize = (1 << Int(log2)) + VaultFileFormat.tagLength

        let salt = Data(header.suffix(VaultFileFormat.saltLength))
        let key = fileKey(masterKey: masterKey, salt: salt)
        let aad = header + idBytes(fileID)

        var counter: UInt32 = 0

        var current = try input.read(upToCount: cipherChunkSize) ?? Data()

        while true {

            let following = try input.read(upToCount: cipherChunkSize) ?? Data()
            let isLast = following.isEmpty

            // Tutti i chunk tranne l'ultimo devono avere la dimensione piena.
            guard current.count >= VaultFileFormat.tagLength,
                  isLast || current.count == cipherChunkSize
            else {
                throw VaultCryptoError.invalidFile
            }

            let plain: Data

            do {

                let box = try AES.GCM.SealedBox(
                    nonce: try chunkNonce(counter: counter, isLast: isLast),
                    ciphertext: current.prefix(current.count - VaultFileFormat.tagLength),
                    tag: current.suffix(VaultFileFormat.tagLength)
                )

                plain = try AES.GCM.open(box, using: key, authenticating: aad)

            } catch {

                throw VaultCryptoError.authenticationFailed
            }

            try sink(plain)

            if isLast {
                break
            }

            counter += 1
            current = following
        }
    }

    /// Decifra in memoria (miniature). Rifiuta file più grandi di `maximumSize`.
    static func decryptToData(
        from source: URL,
        fileID: UUID,
        masterKey: SymmetricKey,
        maximumSize: Int
    ) throws -> Data {

        var result = Data()

        try decryptStream(
            from: source,
            fileID: fileID,
            masterKey: masterKey
        ) { chunk in

            guard result.count + chunk.count <= maximumSize else {
                throw CocoaError(.fileReadTooLarge)
            }

            result.append(chunk)
        }

        return result
    }

    /// Decifra su un file nuovo (protetto). In caso di errore il file parziale viene eliminato.
    static func decryptFile(
        from source: URL,
        to destination: URL,
        fileID: UUID,
        masterKey: SymmetricKey
    ) throws {

        guard FileManager.default.createFile(
            atPath: destination.path,
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.complete]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let output = try FileHandle(forWritingTo: destination)

        do {

            try decryptStream(
                from: source,
                fileID: fileID,
                masterKey: masterKey
            ) { chunk in
                try output.write(contentsOf: chunk)
            }

            try output.synchronize()
            try output.close()

        } catch {

            try? output.close()
            try? FileManager.default.removeItem(at: destination)

            throw error
        }
    }
}
