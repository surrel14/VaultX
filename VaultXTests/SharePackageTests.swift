import XCTest
@testable import VaultX

final class SharePackageTests: XCTestCase {

    private let password = "correct horse battery"

    private var tempRoot: URL!

    override func setUpWithError() throws {

        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "VaultXShareTests-\(UUID().uuidString)",
                isDirectory: true
            )

        try FileManager.default.createDirectory(
            at: tempRoot,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Helpers

    private func makePackage(
        contents: Data,
        name: String = "contratto.pdf",
        password: String? = nil,
        expiresAt: Date? = nil
    ) throws -> URL {

        let source = tempRoot.appendingPathComponent("source-\(UUID().uuidString)")
        try contents.write(to: source)

        let package = tempRoot.appendingPathComponent(
            "\(UUID().uuidString).\(SharePackage.fileExtension)"
        )

        try SharePackage.create(
            from: source,
            name: name,
            password: password ?? self.password,
            expiresAt: expiresAt,
            to: package
        )

        return package
    }

    // MARK: - Reference implementation

    /// Pacchetto prodotto da `docs/vaultx_share_ref.py` (Python, libreria `cryptography`).
    private let referencePackageBase64: String = """
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
"""
        .replacingOccurrences(of: "\n", with: "")

    func testOpensPackageProducedByReferenceImplementation() throws {

        let blob = try XCTUnwrap(Data(base64Encoded: referencePackageBase64))

        let url = tempRoot.appendingPathComponent("reference.\(SharePackage.fileExtension)")
        try blob.write(to: url)

        let info = try SharePackage.inspect(url)

        XCTAssertEqual(info.expiresAt?.timeIntervalSince1970, 4_102_444_800)
        XCTAssertFalse(info.isExpired)

        let opened = try SharePackage.open(url, password: password)

        XCTAssertEqual(opened.metadata.name, "ref-note.txt")
        XCTAssertEqual(opened.metadata.size, 3_000)

        let expected = Data((0 ..< 3_000).map { UInt8(($0 * 5 + 1) % 256) })

        XCTAssertEqual(try Data(contentsOf: opened.fileURL), expected)

        XCTAssertThrowsError(try SharePackage.open(url, password: "wrong password!"))
    }

    // MARK: - Tests

    func testRoundTripWithMultipleChunks() throws {

        // 200.000 byte: più chunk da 64 KiB (l'ultimo parziale).
        let plain = Data((0 ..< 200_000).map { UInt8($0 % 251) })

        let package = try makePackage(contents: plain)

        let opened = try SharePackage.open(package, password: password)

        XCTAssertEqual(opened.metadata.name, "contratto.pdf")
        XCTAssertEqual(opened.metadata.size, 200_000)
        XCTAssertEqual(opened.fileURL.lastPathComponent, "contratto.pdf")
        XCTAssertEqual(try Data(contentsOf: opened.fileURL), plain)
    }

    func testEmptyAndTinyFiles() throws {

        for size in [0, 1, 65_535, 65_536, 65_537] {

            let plain = Data((0 ..< size).map { UInt8($0 % 199) })

            let package = try makePackage(contents: plain, name: "f\(size).bin")

            let opened = try SharePackage.open(package, password: password)

            XCTAssertEqual(try Data(contentsOf: opened.fileURL), plain, "size \(size)")
        }
    }

    func testWrongPasswordFails() throws {

        let package = try makePackage(contents: Data("segreto".utf8))

        XCTAssertThrowsError(
            try SharePackage.open(package, password: "wrong password!")
        ) { error in

            guard case SharePackageError.wrongPasswordOrCorrupted = error else {
                return XCTFail("\(error)")
            }
        }
    }

    func testPasswordIsNormalized() throws {

        let composed = "caff\u{00E8}-lungo-123"
        let decomposed = "caffe\u{0300}-lungo-123"

        let package = try makePackage(contents: Data("x".utf8), password: composed)

        let opened = try SharePackage.open(package, password: decomposed)

        XCTAssertEqual(try String(contentsOf: opened.fileURL, encoding: .utf8), "x")
    }

    func testExpiry() throws {

        // Scaduto: rifiutato prima ancora di chiedere la password giusta.
        let expired = try makePackage(
            contents: Data("x".utf8),
            expiresAt: Date().addingTimeInterval(-3_600)
        )

        XCTAssertTrue(try SharePackage.inspect(expired).isExpired)

        XCTAssertThrowsError(try SharePackage.open(expired, password: password)) { error in

            guard case SharePackageError.expired = error else {
                return XCTFail("\(error)")
            }
        }

        // Non ancora scaduto.
        let valid = try makePackage(
            contents: Data("x".utf8),
            expiresAt: Date().addingTimeInterval(3_600)
        )

        let info = try SharePackage.inspect(valid)

        XCTAssertFalse(info.isExpired)
        XCTAssertNotNil(info.expiresAt)

        XCTAssertNoThrow(try SharePackage.open(valid, password: password))

        // Nessuna scadenza.
        let forever = try makePackage(contents: Data("x".utf8))

        XCTAssertNil(try SharePackage.inspect(forever).expiresAt)
    }

    func testExpiryCannotBeRemovedByEditingTheHeader() throws {

        let package = try makePackage(
            contents: Data("x".utf8),
            expiresAt: Date().addingTimeInterval(-3_600)
        )

        var bytes = try Data(contentsOf: package)

        // Azzera la scadenza (ultimi 8 byte dell'header): il pacchetto non deve più aprirsi.
        for offset in 43 ..< 51 {
            bytes[offset] = 0
        }

        let tampered = tempRoot.appendingPathComponent("manomesso.vaultxshare")
        try bytes.write(to: tampered)

        XCTAssertNil(try SharePackage.inspect(tampered).expiresAt)

        XCTAssertThrowsError(try SharePackage.open(tampered, password: password)) { error in

            guard case SharePackageError.wrongPasswordOrCorrupted = error else {
                return XCTFail("\(error)")
            }
        }
    }

    func testTamperedContentIsDetected() throws {

        let package = try makePackage(contents: Data((0 ..< 5_000).map { UInt8($0 % 100) }))

        var bytes = try Data(contentsOf: package)
        bytes[bytes.count - 20] ^= 0x01

        let tampered = tempRoot.appendingPathComponent("alterato.vaultxshare")
        try bytes.write(to: tampered)

        XCTAssertThrowsError(try SharePackage.open(tampered, password: password))
    }

    func testFileNameIsNotVisibleInThePackage() throws {

        let package = try makePackage(
            contents: Data("dati".utf8),
            name: "estratto-conto-riservato.pdf"
        )

        let bytes = try Data(contentsOf: package)

        XCTAssertNil(bytes.range(of: Data("estratto".utf8)))
        XCTAssertNil(bytes.range(of: Data("riservato".utf8)))
    }

    func testRejectsFilesThatAreNotPackages() throws {

        let junk = tempRoot.appendingPathComponent("junk.vaultxshare")
        try Data("non sono un pacchetto protetto, ma sono abbastanza lungo".utf8).write(to: junk)

        XCTAssertThrowsError(try SharePackage.inspect(junk)) { error in

            guard case SharePackageError.notAPackage = error else {
                return XCTFail("\(error)")
            }
        }
    }

    func testUnsafeNameIsSanitized() throws {

        let package = try makePackage(
            contents: Data("x".utf8),
            name: "../../evil.txt"
        )

        let opened = try SharePackage.open(package, password: password)

        XCTAssertFalse(opened.fileURL.lastPathComponent.contains("/"))
        XCTAssertTrue(opened.fileURL.path.contains("VaultXOpen"))
    }
}
