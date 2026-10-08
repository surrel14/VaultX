import XCTest
import CryptoKit
@testable import VaultX

final class VaultSecurityTests: XCTestCase {

    private var tempRoot: URL!
    private var store: VaultStore!

    override func setUpWithError() throws {

        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "VaultXSecurityTests-\(UUID().uuidString)",
                isDirectory: true
            )

        store = VaultStore(rootURL: tempRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Helpers

    /// Wrap nel formato della v0.2 ("VLWK01", 210k iterazioni, password usata così com'è).
    private func legacyWrap(_ masterKey: Data, password: String) throws -> Data {

        let salt = try VaultCrypto.randomBytes(count: VaultCrypto.saltLength)
        let key = try VaultCrypto.deriveKey(password: password, salt: salt)
        let nonceData = try VaultCrypto.randomBytes(count: VaultCrypto.nonceLength)
        let nonce = try AES.GCM.Nonce(data: nonceData)

        let sealed = try AES.GCM.seal(masterKey, using: key, nonce: nonce)

        var result = Data("VLWK01".utf8)
        result.append(salt)
        result.append(nonceData)
        result.append(sealed.ciphertext)
        result.append(sealed.tag)

        return result
    }

    // MARK: - Wrap format

    func testNewWrapUsesCurrentFormatAndIterations() throws {

        let master = try VaultCrypto.generateMasterKey()
        let wrapped = try VaultCrypto.wrapMasterKey(master, password: "correct horse battery")

        XCTAssertTrue(wrapped.starts(with: Data("VLWK03".utf8)))

        let iterations = Array(wrapped[6 ..< 10])
            .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }

        XCTAssertEqual(iterations, VaultCrypto.wrapIterations)
        XCTAssertEqual(iterations, 600_000)
    }

    func testLegacyWrapStillUnwraps() throws {

        let master = try VaultCrypto.generateMasterKey()
        let legacy = try legacyWrap(master, password: "correct horse battery")

        let unwrapped = try VaultCrypto.unwrapMasterKey(legacy, password: "correct horse battery")

        XCTAssertEqual(unwrapped, master)

        XCTAssertThrowsError(
            try VaultCrypto.unwrapMasterKey(legacy, password: "wrong password!!")
        )
    }

    func testPasswordNormalizationAcceptsDecomposedInput() throws {

        let composed = "caff\u{00E8}-lungo-123"      // è precomposta
        let decomposed = "caffe\u{0300}-lungo-123"   // e + accento combinato

        let master = try VaultCrypto.generateMasterKey()

        // Nuovo formato: stessa password con tastiere diverse.
        let wrapped = try VaultCrypto.wrapMasterKey(master, password: composed)

        XCTAssertEqual(
            try VaultCrypto.unwrapMasterKey(wrapped, password: decomposed),
            master
        )

        // Vecchio formato: la password originale non era normalizzata.
        let legacy = try legacyWrap(master, password: composed)

        XCTAssertEqual(
            try VaultCrypto.unwrapMasterKey(legacy, password: decomposed),
            master
        )
    }

    func testTamperedWrapHeaderFailsAuthentication() throws {

        let master = try VaultCrypto.generateMasterKey()

        var wrapped = try VaultCrypto.wrapMasterKey(master, password: "correct horse battery")

        // Cambiare i byte delle iterazioni (autenticati come AAD) deve far fallire l'apertura.
        wrapped[9] ^= 0x01

        XCTAssertThrowsError(
            try VaultCrypto.unwrapMasterKey(wrapped, password: "correct horse battery")
        )
    }

    // MARK: - Recovery key

    func testRecoveryKeyFormatAndParse() throws {

        let secret = try RecoveryKey.generate()

        let text = RecoveryKey.format(secret)

        XCTAssertEqual(text.replacingOccurrences(of: "-", with: "").count, 52)
        XCTAssertEqual(text.split(separator: "-").count, 13)

        XCTAssertEqual(RecoveryKey.parse(text), secret)
        XCTAssertEqual(RecoveryKey.parse(text.lowercased()), secret)
        XCTAssertEqual(
            RecoveryKey.parse(text.replacingOccurrences(of: "-", with: " ")),
            secret
        )

        XCTAssertNil(RecoveryKey.parse("non una chiave"))
        XCTAssertNil(RecoveryKey.parse("ABCD-EFGH"))
    }

    func testRecoveryWrapRoundTrip() throws {

        let master = try VaultCrypto.generateMasterKey()
        let secret = try RecoveryKey.generate()

        let wrapped = try VaultCrypto.wrapMasterKey(master, recoverySecret: secret)

        XCTAssertEqual(
            try VaultCrypto.unwrapMasterKey(wrapped, recoverySecret: secret),
            master
        )

        let other = try RecoveryKey.generate()

        XCTAssertThrowsError(
            try VaultCrypto.unwrapMasterKey(wrapped, recoverySecret: other)
        )
    }

    // MARK: - Vault level

    func testChangePassword() throws {

        let url = try store.createVault(named: "Pw", password: "old password 1")

        try store.changePassword(
            at: url,
            oldPassword: "old password 1",
            newPassword: "new password 2"
        )

        XCTAssertThrowsError(try store.unlockVault(at: url, password: "old password 1"))

        let session = try store.unlockVault(at: url, password: "new password 2")
        session.lock()
    }

    func testChangePasswordRejectsWrongOldAndWeakNew() throws {

        let url = try store.createVault(named: "Pw2", password: "old password 1")

        XCTAssertThrowsError(
            try store.changePassword(at: url, oldPassword: "nope nope nope", newPassword: "new password 2")
        )

        XCTAssertThrowsError(
            try store.changePassword(at: url, oldPassword: "old password 1", newPassword: "short")
        )

        // La password originale funziona ancora.
        let session = try store.unlockVault(at: url, password: "old password 1")
        session.lock()
    }

    func testChangePasswordKeepsFilesReadable() throws {

        let url = try store.createVault(named: "Files", password: "old password 1")

        let first = try store.unlockVault(at: url, password: "old password 1")

        let source = tempRoot.appendingPathComponent("nota.txt")
        try Data("segreto".utf8).write(to: source)

        try first.importFile(at: source, into: first.rootDirectory)
        first.lock()

        try store.changePassword(
            at: url,
            oldPassword: "old password 1",
            newPassword: "new password 2"
        )

        let second = try store.unlockVault(at: url, password: "new password 2")

        let item = try XCTUnwrap(second.items(in: second.rootDirectory).first)
        let plain = try second.decryptToTemporaryFile(item.url)

        XCTAssertEqual(try String(contentsOf: plain, encoding: .utf8), "segreto")

        second.lock()
    }

    func testRecoveryKeyResetsPassword() throws {

        let url = try store.createVault(named: "Rec", password: "old password 1")

        let session = try store.unlockVault(at: url, password: "old password 1")

        XCTAssertFalse(store.hasRecoveryKey(at: url))

        let key = try store.createRecoveryKey(for: session)

        XCTAssertTrue(store.hasRecoveryKey(at: url))

        session.lock()

        // Chiave sbagliata (formato valido) -> errore.
        let wrongKey = RecoveryKey.format(Data(repeating: 7, count: 32))

        XCTAssertThrowsError(
            try store.resetPassword(at: url, recoveryKey: wrongKey, newPassword: "brand new pass")
        )

        // Chiave giusta (anche in minuscolo) -> nuova password.
        try store.resetPassword(
            at: url,
            recoveryKey: key.lowercased(),
            newPassword: "brand new pass"
        )

        XCTAssertThrowsError(try store.unlockVault(at: url, password: "old password 1"))

        let reopened = try store.unlockVault(at: url, password: "brand new pass")
        reopened.lock()
    }

    func testRemoveRecoveryKey() throws {

        let url = try store.createVault(named: "Rec2", password: "old password 1")

        let session = try store.unlockVault(at: url, password: "old password 1")

        _ = try store.createRecoveryKey(for: session)

        try store.removeRecoveryKey(at: url)

        XCTAssertFalse(store.hasRecoveryKey(at: url))

        session.lock()
    }
}
