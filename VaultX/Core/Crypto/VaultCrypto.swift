import Foundation
import CryptoKit
import CommonCrypto
import Security

enum VaultCryptoError: LocalizedError {
    case invalidPassword
    case invalidFile
    case authenticationFailed
    case randomGenerationFailed

    var errorDescription: String? {
        switch self {
        case .invalidPassword: return "La password non è valida."
        case .invalidFile: return "Il file cifrato non è un formato VaultX valido."
        case .authenticationFailed: return "Password errata o dati corrotti."
        case .randomGenerationFailed: return "Impossibile generare dati casuali sicuri."
        }
    }
}

struct VaultCrypto {
    static let version: UInt8 = 2
    static let saltLength = 16
    static let nonceLength = 12
    static let tagLength = 16
    static let keyLength = 32
    static let iterations: UInt32 = 210_000

    static func randomBytes(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw VaultCryptoError.randomGenerationFailed }
        return data
    }

    static func generateMasterKey() throws -> Data {
        try randomBytes(count: keyLength)
    }

    /// Derivazione con le iterazioni "legacy" (vault creati con la v0.2).
    static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        try deriveKey(password: password, salt: salt, iterations: iterations)
    }

    static func deriveKey(
        password: String,
        salt: Data,
        iterations: UInt32
    ) throws -> SymmetricKey {
        guard !password.isEmpty else { throw VaultCryptoError.invalidPassword }
        var output = Data(count: keyLength)
        let passwordData = Data(password.utf8)
        let status = output.withUnsafeMutableBytes { outBuffer in
            passwordData.withUnsafeBytes { passBuffer in
                salt.withUnsafeBytes { saltBuffer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passBuffer.bindMemory(to: Int8.self).baseAddress,
                        passwordData.count,
                        saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        outBuffer.bindMemory(to: UInt8.self).baseAddress,
                        keyLength
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw VaultCryptoError.invalidPassword }
        return SymmetricKey(data: output)
    }

    /// Dimensione fissa dell'envelope: magic 6 + versione 1 + nonce + tag.
    static let envelopeOverhead = 6 + 1 + nonceLength + tagLength

    /// VaultX v2 envelope:
    /// [magic 6][version 1][nonce 12][ciphertext N][tag 16]
    static func encrypt(_ plaintext: Data, using keyData: Data) throws -> Data {
        guard keyData.count == keyLength else { throw VaultCryptoError.invalidFile }
        return try encrypt(plaintext, using: SymmetricKey(data: keyData))
    }

    /// Variante con `SymmetricKey`: la VaultSession passa una chiave temporanea
    /// (CryptoKit la azzera quando viene rilasciata) senza esporre `Data`.
    static func encrypt(_ plaintext: Data, using key: SymmetricKey) throws -> Data {
        let nonceData = try randomBytes(count: nonceLength)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)

        var result = Data("VLTX02".utf8)
        result.append(version)
        result.append(nonceData)
        result.append(sealed.ciphertext)
        result.append(sealed.tag)
        return result
    }

    static func decrypt(_ encrypted: Data, using keyData: Data) throws -> Data {
        guard keyData.count == keyLength else { throw VaultCryptoError.invalidFile }
        return try decrypt(encrypted, using: SymmetricKey(data: keyData))
    }

    static func decrypt(_ encrypted: Data, using key: SymmetricKey) throws -> Data {
        let magic = Data("VLTX02".utf8)
        guard encrypted.count >= magic.count + 1 + nonceLength + tagLength else {
            throw VaultCryptoError.invalidFile
        }
        guard encrypted.prefix(magic.count) == magic else { throw VaultCryptoError.invalidFile }
        guard encrypted[magic.count] == version else { throw VaultCryptoError.invalidFile }

        let nonceStart = magic.count + 1
        let bodyStart = nonceStart + nonceLength
        let nonceData = encrypted[nonceStart..<bodyStart]
        let body = encrypted[bodyStart...]
        guard body.count >= tagLength else { throw VaultCryptoError.invalidFile }

        let ciphertext = body.prefix(body.count - tagLength)
        let tag = body.suffix(tagLength)

        do {
            let nonce = try AES.GCM.Nonce(data: Data(nonceData))
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: Data(ciphertext), tag: Data(tag))
            return try AES.GCM.open(box, using: key)
        } catch {
            throw VaultCryptoError.authenticationFailed
        }
    }

    // MARK: - Password wrapping

    /// Iterazioni PBKDF2-HMAC-SHA256 per i nuovi wrap (raccomandazione OWASP 2023).
    static let wrapIterations: UInt32 = 600_000

    private static let wrapMagicV3 = Data("VLWK03".utf8)
    private static let wrapMagicV1 = Data("VLWK01".utf8)

    /// Normalizza la password (NFC): la stessa password digitata con tastiere
    /// diverse produce così gli stessi byte.
    static func normalized(_ password: String) -> String {
        password.precomposedStringWithCanonicalMapping
    }

    /// Wrap v3:
    /// [magic "VLWK03" 6][iterazioni UInt32 BE 4][salt 16][nonce 12][ciphertext 32][tag 16]
    /// Magic, iterazioni e salt sono autenticati (AAD).
    static func wrapMasterKey(_ masterKey: Data, password: String) throws -> Data {

        guard masterKey.count == keyLength else { throw VaultCryptoError.invalidFile }

        let salt = try randomBytes(count: saltLength)

        var header = wrapMagicV3
        header.append(contentsOf: withUnsafeBytes(of: wrapIterations.bigEndian) { Array($0) })
        header.append(salt)

        let passwordKey = try deriveKey(
            password: normalized(password),
            salt: salt,
            iterations: wrapIterations
        )

        let nonceData = try randomBytes(count: nonceLength)
        let nonce = try AES.GCM.Nonce(data: nonceData)

        let sealed = try AES.GCM.seal(
            masterKey,
            using: passwordKey,
            nonce: nonce,
            authenticating: header
        )

        var result = header
        result.append(nonceData)
        result.append(sealed.ciphertext)
        result.append(sealed.tag)
        return result
    }

    /// Legge sia il formato v3 sia quello legacy "VLWK01" (210k iterazioni).
    static func unwrapMasterKey(_ wrapped: Data, password: String) throws -> Data {

        if wrapped.starts(with: wrapMagicV3) {
            return try unwrapV3(wrapped, password: password)
        }

        if wrapped.starts(with: wrapMagicV1) {
            return try unwrapLegacy(wrapped, password: password)
        }

        throw VaultCryptoError.invalidFile
    }

    private static func unwrapV3(_ wrapped: Data, password: String) throws -> Data {

        let magicLength = wrapMagicV3.count
        let headerLength = magicLength + 4 + saltLength

        guard wrapped.count >= headerLength + nonceLength + keyLength + tagLength else {
            throw VaultCryptoError.invalidFile
        }

        let bytes = Array(wrapped)

        let iterationCount = bytes[magicLength ..< magicLength + 4]
            .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }

        // Valori assurdi = file corrotto/manomesso (e niente blocchi infiniti).
        guard iterationCount >= 100_000, iterationCount <= 10_000_000 else {
            throw VaultCryptoError.invalidFile
        }

        let header = Data(bytes[0 ..< headerLength])
        let salt = Data(bytes[(headerLength - saltLength) ..< headerLength])
        let nonceData = Data(bytes[headerLength ..< headerLength + nonceLength])
        let body = Data(bytes[(headerLength + nonceLength)...])

        let ciphertext = Data(body.prefix(body.count - tagLength))
        let tag = Data(body.suffix(tagLength))

        do {

            let passwordKey = try deriveKey(
                password: normalized(password),
                salt: salt,
                iterations: iterationCount
            )

            let nonce = try AES.GCM.Nonce(data: nonceData)

            let box = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: ciphertext,
                tag: tag
            )

            let masterKey = try AES.GCM.open(
                box,
                using: passwordKey,
                authenticating: header
            )

            guard masterKey.count == keyLength else {
                throw VaultCryptoError.invalidFile
            }

            return masterKey

        } catch VaultCryptoError.invalidFile {
            throw VaultCryptoError.invalidFile
        } catch {
            throw VaultCryptoError.authenticationFailed
        }
    }

    /// Formato v0.2: [magic "VLWK01" 6][salt 16][nonce 12][ciphertext 32][tag 16], 210k iterazioni.
    /// La password veniva usata così com'era (senza normalizzazione): proviamo prima
    /// quella e poi la versione NFC.
    private static func unwrapLegacy(_ wrapped: Data, password: String) throws -> Data {

        let magicLength = wrapMagicV1.count

        guard wrapped.count >= magicLength + saltLength + nonceLength + keyLength + tagLength else {
            throw VaultCryptoError.invalidFile
        }

        let bytes = Array(wrapped)

        let salt = Data(bytes[magicLength ..< magicLength + saltLength])
        let nonceStart = magicLength + saltLength
        let nonceData = Data(bytes[nonceStart ..< nonceStart + nonceLength])
        let body = Data(bytes[(nonceStart + nonceLength)...])

        let ciphertext = Data(body.prefix(body.count - tagLength))
        let tag = Data(body.suffix(tagLength))

        // Candidati: la password così com'è, in forma NFC e in forma NFD.
        // Attenzione: in Swift due stringhe canonicamente equivalenti sono "uguali"
        // anche se hanno byte diversi, quindi i duplicati si scartano confrontando i byte UTF-8.
        var candidates: [String] = []
        var seen = Set<[UInt8]>()

        let variants = [
            password,
            normalized(password),
            password.decomposedStringWithCanonicalMapping
        ]

        for variant in variants where seen.insert(Array(variant.utf8)).inserted {
            candidates.append(variant)
        }

        for candidate in candidates {

            guard let key = try? deriveKey(password: candidate, salt: salt),
                  let nonce = try? AES.GCM.Nonce(data: nonceData),
                  let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag),
                  let masterKey = try? AES.GCM.open(box, using: key),
                  masterKey.count == keyLength
            else {
                continue
            }

            return masterKey
        }

        throw VaultCryptoError.authenticationFailed
    }

    // MARK: - Recovery key wrapping

    static let recoveryKeyLength = 32

    private static let recoveryMagic = Data("VLRK01".utf8)

    /// Chiave di recupero: un segreto casuale da 256 bit (non una password), quindi
    /// basta HKDF. Formato: [magic "VLRK01" 6][salt 16][nonce 12][ciphertext 32][tag 16].
    static func wrapMasterKey(_ masterKey: Data, recoverySecret: Data) throws -> Data {

        guard masterKey.count == keyLength,
              recoverySecret.count == recoveryKeyLength
        else {
            throw VaultCryptoError.invalidFile
        }

        let salt = try randomBytes(count: saltLength)

        var header = recoveryMagic
        header.append(salt)

        let key = recoveryWrapKey(secret: recoverySecret, salt: salt)

        let nonceData = try randomBytes(count: nonceLength)
        let nonce = try AES.GCM.Nonce(data: nonceData)

        let sealed = try AES.GCM.seal(
            masterKey,
            using: key,
            nonce: nonce,
            authenticating: header
        )

        var result = header
        result.append(nonceData)
        result.append(sealed.ciphertext)
        result.append(sealed.tag)
        return result
    }

    static func unwrapMasterKey(_ wrapped: Data, recoverySecret: Data) throws -> Data {

        let magicLength = recoveryMagic.count
        let headerLength = magicLength + saltLength

        guard recoverySecret.count == recoveryKeyLength,
              wrapped.starts(with: recoveryMagic),
              wrapped.count >= headerLength + nonceLength + keyLength + tagLength
        else {
            throw VaultCryptoError.invalidFile
        }

        let bytes = Array(wrapped)

        let header = Data(bytes[0 ..< headerLength])
        let salt = Data(bytes[magicLength ..< headerLength])
        let nonceData = Data(bytes[headerLength ..< headerLength + nonceLength])
        let body = Data(bytes[(headerLength + nonceLength)...])

        let ciphertext = Data(body.prefix(body.count - tagLength))
        let tag = Data(body.suffix(tagLength))

        do {

            let key = recoveryWrapKey(secret: recoverySecret, salt: salt)
            let nonce = try AES.GCM.Nonce(data: nonceData)

            let box = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: ciphertext,
                tag: tag
            )

            let masterKey = try AES.GCM.open(
                box,
                using: key,
                authenticating: header
            )

            guard masterKey.count == keyLength else {
                throw VaultCryptoError.invalidFile
            }

            return masterKey

        } catch VaultCryptoError.invalidFile {
            throw VaultCryptoError.invalidFile
        } catch {
            throw VaultCryptoError.authenticationFailed
        }
    }

    private static func recoveryWrapKey(secret: Data, salt: Data) -> SymmetricKey {

        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: salt,
            info: Data("VaultX recovery key v1".utf8),
            outputByteCount: keyLength
        )
    }
}
