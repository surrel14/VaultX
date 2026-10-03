import XCTest
@testable import VaultX

final class VaultCryptoTests: XCTestCase {
    func testPasswordWrapAndUnwrap() throws {
        let master = try VaultCrypto.generateMasterKey()
        let wrapped = try VaultCrypto.wrapMasterKey(master, password: "correct horse battery")
        let unwrapped = try VaultCrypto.unwrapMasterKey(wrapped, password: "correct horse battery")
        XCTAssertEqual(master, unwrapped)
    }

    func testWrongPasswordFails() throws {
        let master = try VaultCrypto.generateMasterKey()
        let wrapped = try VaultCrypto.wrapMasterKey(master, password: "correct password")
        XCTAssertThrowsError(try VaultCrypto.unwrapMasterKey(wrapped, password: "wrong password"))
    }

    func testFileRoundTrip() throws {
        let key = try VaultCrypto.generateMasterKey()
        let original = Data("VaultX encrypted data".utf8)
        let encrypted = try VaultCrypto.encrypt(original, using: key)
        XCTAssertNotEqual(encrypted, original)
        let decrypted = try VaultCrypto.decrypt(encrypted, using: key)
        XCTAssertEqual(decrypted, original)
    }

    func testTamperedDataFailsAuthentication() throws {
        let key = try VaultCrypto.generateMasterKey()
        var encrypted = try VaultCrypto.encrypt(Data("secret".utf8), using: key)
        encrypted[encrypted.index(before: encrypted.endIndex)] ^= 0x01
        XCTAssertThrowsError(try VaultCrypto.decrypt(encrypted, using: key))
    }

    func testEmptyPasswordIsRejected() {
        XCTAssertThrowsError(try VaultCrypto.deriveKey(password: "", salt: Data(repeating: 0, count: VaultCrypto.saltLength)))
    }
}
