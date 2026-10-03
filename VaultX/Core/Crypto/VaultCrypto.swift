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

    static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
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

    /// VaultX v2 envelope:
    /// [magic 6][version 1][salt 16][nonce 12][ciphertext N][tag 16]
    static func encrypt(_ plaintext: Data, using keyData: Data) throws -> Data {
        guard keyData.count == keyLength else { throw VaultCryptoError.invalidFile }
        let key = SymmetricKey(data: keyData)
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
        let key = SymmetricKey(data: keyData)

        do {
            let nonce = try AES.GCM.Nonce(data: Data(nonceData))
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: Data(ciphertext), tag: Data(tag))
            return try AES.GCM.open(box, using: key)
        } catch {
            throw VaultCryptoError.authenticationFailed
        }
    }

    /// Wraps a random vault master key with a password-derived key.
    static func wrapMasterKey(_ masterKey: Data, password: String) throws -> Data {
        guard masterKey.count == keyLength else { throw VaultCryptoError.invalidFile }
        let salt = try randomBytes(count: saltLength)
        let passwordKey = try deriveKey(password: password, salt: salt)
        let nonceData = try randomBytes(count: nonceLength)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealed = try AES.GCM.seal(masterKey, using: passwordKey, nonce: nonce)

        var result = Data("VLWK01".utf8)
        result.append(salt)
        result.append(nonceData)
        result.append(sealed.ciphertext)
        result.append(sealed.tag)
        return result
    }

    static func unwrapMasterKey(_ wrapped: Data, password: String) throws -> Data {
        let magic = Data("VLWK01".utf8)
        let minimum = magic.count + saltLength + nonceLength + keyLength + tagLength
        guard wrapped.count >= minimum, wrapped.prefix(magic.count) == magic else {
            throw VaultCryptoError.invalidFile
        }

        let saltStart = magic.count
        let nonceStart = saltStart + saltLength
        let bodyStart = nonceStart + nonceLength
        let salt = wrapped[saltStart..<nonceStart]
        let nonceData = wrapped[nonceStart..<bodyStart]
        let body = wrapped[bodyStart...]
        let ciphertext = body.prefix(body.count - tagLength)
        let tag = body.suffix(tagLength)

        do {
            let passwordKey = try deriveKey(password: password, salt: Data(salt))
            let nonce = try AES.GCM.Nonce(data: Data(nonceData))
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: Data(ciphertext), tag: Data(tag))
            let masterKey = try AES.GCM.open(box, using: passwordKey)
            guard masterKey.count == keyLength else { throw VaultCryptoError.invalidFile }
            return masterKey
        } catch VaultCryptoError.invalidFile {
            throw VaultCryptoError.invalidFile
        } catch {
            throw VaultCryptoError.authenticationFailed
        }
    }
}
