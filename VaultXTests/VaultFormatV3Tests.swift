import XCTest
import CryptoKit
@testable import VaultX

/// Test del formato file v3 e del suo comportamento a livello di vault.
/// I vettori di test sono stati generati con un'implementazione di riferimento
/// indipendente (Python, libreria `cryptography`, vedi docs/VAULT_FORMAT_V3.md).
final class VaultFormatV3Tests: XCTestCase {

    private var tempRoot: URL!
    private var store: VaultStore!

    private let password = "correct horse battery"

    override func setUpWithError() throws {

        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "VaultXFormatTests-\(UUID().uuidString)",
                isDirectory: true
            )

        try FileManager.default.createDirectory(
            at: tempRoot,
            withIntermediateDirectories: true
        )

        store = VaultStore(rootURL: tempRoot.appendingPathComponent("Vaults"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Helpers

    private func hex(_ key: SymmetricKey) -> String {
        key.withUnsafeBytes { Data($0) }
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func write(_ data: Data, named name: String) throws -> URL {

        let url = tempRoot.appendingPathComponent(name)
        try data.write(to: url)

        return url
    }

    private func makeSession(
        name: String = "Vault"
    ) throws -> (url: URL, session: VaultSession) {

        let url = try store.createVault(named: name, password: password)
        let session = try store.unlockVault(at: url, password: password)

        return (url, session)
    }

    private func allFilePaths(in directory: URL) -> [String] {

        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        )

        var paths: [String] = []

        while let url = enumerator?.nextObject() as? URL {
            paths.append(url.path)
        }

        return paths
    }

    // MARK: - Known-answer vectors (reference implementation)

    private let master = SymmetricKey(data: Data(0..<32))
    private let vectorFileID = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!

    private var vectorPlaintext: Data {
        Data((0..<2500).map { UInt8(($0 * 7 + 3) % 256) })
    }

    private let vectorBase64: String = """
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
D99NsHrCwrzoZitj3vLqB7i5jtOIrQ==
"""
        .replacingOccurrences(of: "\n", with: "")


    func testKeyDerivationMatchesReference() {

        let salt = Data(100..<132)

        XCTAssertEqual(
            hex(VaultCrypto.fileKey(masterKey: master, salt: salt)),
            "56c4a614a3fbe41eb78fd0d4ca7bc14e238d0dad51a8bd2307568deb4f3adf24"
        )

        XCTAssertEqual(
            hex(VaultCrypto.indexKey(masterKey: master)),
            "ee17a313de39948275ce97954673f6191301f1fa3b74d1904a19ce568ccb9ac7"
        )
    }

    func testDecryptsFileProducedByReferenceImplementation() throws {

        let blob = try XCTUnwrap(Data(base64Encoded: vectorBase64))
        let url = try write(blob, named: "vector.vltx")

        let plain = try VaultCrypto.decryptToData(
            from: url,
            fileID: vectorFileID,
            masterKey: master,
            maximumSize: 1_000_000
        )

        XCTAssertEqual(plain, vectorPlaintext)

        XCTAssertEqual(
            VaultCrypto.plaintextSize(forEncryptedSize: Int64(blob.count), chunkSizeLog2: 10),
            2500
        )
    }

    func testReferenceFileFailsWithWrongID() throws {

        let blob = try XCTUnwrap(Data(base64Encoded: vectorBase64))
        let url = try write(blob, named: "vector.vltx")

        XCTAssertThrowsError(
            try VaultCrypto.decryptToData(
                from: url,
                fileID: UUID(),
                masterKey: master,
                maximumSize: 1_000_000
            )
        )
    }

    // MARK: - Round trips

    func testRoundTripAroundChunkBoundaries() throws {

        for size in [0, 1, 1023, 1024, 1025, 2048, 3000] {

            let plain = Data((0..<size).map { UInt8($0 % 251) })
            let id = UUID()

            let url = tempRoot.appendingPathComponent("rt-\(size).vltx")

            let written = try VaultCrypto.encryptData(
                plain,
                to: url,
                fileID: id,
                masterKey: master,
                chunkSizeLog2: 10
            )

            XCTAssertEqual(written, Int64(size))

            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let onDisk = (attributes[.size] as? NSNumber)?.int64Value ?? -1

            XCTAssertEqual(
                VaultCrypto.plaintextSize(forEncryptedSize: onDisk, chunkSizeLog2: 10),
                Int64(size),
                "size \(size)"
            )

            let back = try VaultCrypto.decryptToData(
                from: url,
                fileID: id,
                masterKey: master,
                maximumSize: 10_000
            )

            XCTAssertEqual(back, plain, "size \(size)")
        }
    }

    func testStreamingFileRoundTripMultipleChunks() throws {

        // 200.000 byte = 4 chunk da 64 KiB (l'ultimo parziale)
        let plain = Data((0..<200_000).map { UInt8($0 % 253) })

        let source = try write(plain, named: "big.bin")
        let encrypted = tempRoot.appendingPathComponent("big.vltx")
        let decrypted = tempRoot.appendingPathComponent("big.out")
        let id = UUID()

        let size = try VaultCrypto.encryptFile(
            from: source,
            to: encrypted,
            fileID: id,
            masterKey: master
        )

        XCTAssertEqual(size, 200_000)

        try VaultCrypto.decryptFile(
            from: encrypted,
            to: decrypted,
            fileID: id,
            masterKey: master
        )

        XCTAssertEqual(try Data(contentsOf: decrypted), plain)
    }

    // MARK: - Tampering

    func testTamperingTruncationAndWrongIDAreDetected() throws {

        let plain = Data((0..<5000).map { UInt8($0 % 200) })
        let id = UUID()

        let url = tempRoot.appendingPathComponent("t.vltx")

        _ = try VaultCrypto.encryptData(
            plain,
            to: url,
            fileID: id,
            masterKey: master,
            chunkSizeLog2: 10
        )

        let original = try Data(contentsOf: url)

        func decryptsOK(_ data: Data, fileID: UUID? = nil) -> Bool {

            let copy = tempRoot.appendingPathComponent("copy-\(UUID().uuidString)")

            guard (try? data.write(to: copy)) != nil else {
                return false
            }

            return (try? VaultCrypto.decryptToData(
                from: copy,
                fileID: fileID ?? id,
                masterKey: master,
                maximumSize: 100_000
            )) == plain
        }

        XCTAssertTrue(decryptsOK(original))

        // un bit cambiato nel contenuto
        var flipped = original
        flipped[100] ^= 0x01
        XCTAssertFalse(decryptsOK(flipped))

        // un bit cambiato nell'header
        var header = original
        header[10] ^= 0x01
        XCTAssertFalse(decryptsOK(header))

        // troncato esattamente a un confine di chunk
        let chunk = 1024 + 16
        XCTAssertFalse(decryptsOK(original.prefix(VaultFileFormat.headerLength + 2 * chunk)))

        // dati in più in coda
        XCTAssertFalse(decryptsOK(original + Data([1, 2, 3])))

        // ID diverso
        XCTAssertFalse(decryptsOK(original, fileID: UUID()))
    }

    // MARK: - Vault level

    func testNamesAndStructureNeverAppearOnDisk() throws {

        let (url, session) = try makeSession()

        let folder = try session.createFolder(
            named: "Tasse 2026",
            in: session.rootDirectory
        )

        let source = try write(Data("dati".utf8), named: "segreto-conto-bancario.pdf")

        try session.importFile(at: source, into: folder)

        session.lock()

        for path in allFilePaths(in: url) {

            let lower = path.lowercased()

            XCTAssertFalse(lower.contains("segreto"), path)
            XCTAssertFalse(lower.contains("conto"), path)
            XCTAssertFalse(lower.contains("tasse"), path)
            XCTAssertFalse(lower.hasSuffix(".pdf"), path)
        }

        // nemmeno dentro l'indice cifrato
        let indexBytes = try Data(contentsOf: url.appendingPathComponent("index.vaultx"))

        XCTAssertNil(indexBytes.range(of: Data("segreto".utf8)))
        XCTAssertNil(indexBytes.range(of: Data("Tasse".utf8)))

        // ... ma riaprendo il vault ci sono
        let reopened = try store.unlockVault(at: url, password: password)

        XCTAssertEqual(
            try reopened.items(in: reopened.rootDirectory).map(\.name),
            ["Tasse 2026"]
        )

        let folderItem = try XCTUnwrap(
            reopened.items(in: reopened.rootDirectory).first
        )

        XCTAssertEqual(
            try reopened.items(in: folderItem.url).map(\.name),
            ["segreto-conto-bancario.pdf"]
        )

        reopened.lock()
    }

    func testRenameAndMoveDoNotTouchFilesOnDisk() throws {

        let (url, session) = try makeSession()

        let source = try write(Data("x".utf8), named: "a.txt")
        try session.importFile(at: source, into: session.rootDirectory)

        let folder = try session.createFolder(named: "Dest", in: session.rootDirectory)

        let before = Set(allFilePaths(in: url.appendingPathComponent("files")))

        let file = try XCTUnwrap(
            session.items(in: session.rootDirectory).first { !$0.isFolder }
        )

        try session.renameItem(file, to: "renamed.txt")

        let renamed = try XCTUnwrap(
            session.items(in: session.rootDirectory).first { !$0.isFolder }
        )

        try session.moveItem(renamed, to: folder)

        let after = Set(allFilePaths(in: url.appendingPathComponent("files")))

        XCTAssertEqual(before, after)

        XCTAssertEqual(
            try session.items(in: folder).map(\.name),
            ["renamed.txt"]
        )

        session.lock()
    }

    func testSwappingTwoFilesOnDiskIsDetected() throws {

        let (url, session) = try makeSession()

        for name in ["uno.txt", "due.txt"] {

            let source = try write(Data(name.utf8), named: name)
            try session.importFile(at: source, into: session.rootDirectory)
        }

        let files = try session.items(in: session.rootDirectory).sorted { $0.name < $1.name }

        XCTAssertEqual(files.count, 2)

        // scambio dei contenuti cifrati
        let first = files[0].url
        let second = files[1].url

        let a = try Data(contentsOf: first)
        let b = try Data(contentsOf: second)

        try b.write(to: first)
        try a.write(to: second)

        XCTAssertThrowsError(try session.decryptToTemporaryFile(files[0].url))
        XCTAssertThrowsError(try session.decryptToTemporaryFile(files[1].url))

        session.lock()
        _ = url
    }

    func testOrphanFilesAreRemovedAtUnlock() throws {

        let (url, session) = try makeSession()

        let source = try write(Data("x".utf8), named: "keep.txt")
        try session.importFile(at: source, into: session.rootDirectory)

        session.lock()

        let stray = url
            .appendingPathComponent("files")
            .appendingPathComponent("\(UUID().uuidString).vltx")

        try Data("orfano".utf8).write(to: stray)

        let reopened = try store.unlockVault(at: url, password: password)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))

        XCTAssertEqual(
            try reopened.items(in: reopened.rootDirectory).map(\.name),
            ["keep.txt"]
        )

        let item = try XCTUnwrap(reopened.items(in: reopened.rootDirectory).first)
        _ = try reopened.decryptToTemporaryFile(item.url)

        reopened.lock()
    }

    func testIndexIsRecoveredFromBackup() throws {

        let (url, session) = try makeSession()

        try session.createFolder(named: "A", in: session.rootDirectory)
        try session.createFolder(named: "B", in: session.rootDirectory)

        session.lock()

        // indice principale rovinato: resta la copia precedente (con la sola cartella A)
        try Data("rovinato".utf8).write(to: url.appendingPathComponent("index.vaultx"))

        let reopened = try store.unlockVault(at: url, password: password)

        XCTAssertEqual(
            try reopened.items(in: reopened.rootDirectory).map(\.name),
            ["A"]
        )

        reopened.lock()
    }

    func testLargeImportUsesStreamingAndKeepsSize() throws {

        let (_, session) = try makeSession()

        let plain = Data((0..<300_000).map { UInt8($0 % 241) })
        let source = try write(plain, named: "grande.bin")

        try session.importFile(at: source, into: session.rootDirectory)

        let item = try XCTUnwrap(session.items(in: session.rootDirectory).first)

        XCTAssertEqual(item.size, 300_000)

        let out = try session.decryptToTemporaryFile(item.url)

        XCTAssertEqual(try Data(contentsOf: out), plain)

        session.lock()
    }
}
