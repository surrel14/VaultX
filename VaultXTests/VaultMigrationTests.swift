import XCTest
@testable import VaultX

/// Migrazione dei vault v0.2 (nomi in chiaro, file cifrati interi "VLTX02") al formato v3.
final class VaultMigrationTests: XCTestCase {

    private let password = "correct horse battery"

    private var tempRoot: URL!
    private var vaultsRoot: URL!
    private var store: VaultStore!

    override func setUpWithError() throws {

        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "VaultXMigrationTests-\(UUID().uuidString)",
                isDirectory: true
            )

        vaultsRoot = tempRoot.appendingPathComponent("Vaults", isDirectory: true)

        try FileManager.default.createDirectory(
            at: vaultsRoot,
            withIntermediateDirectories: true
        )

        store = VaultStore(rootURL: vaultsRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Helpers

    /// Costruisce a mano un vault nel formato della v0.2.
    private func makeLegacyVault() throws -> URL {

        let fileManager = FileManager.default

        let url = vaultsRoot.appendingPathComponent("Legacy", isDirectory: true)

        try fileManager.createDirectory(
            at: url.appendingPathComponent("data/Documenti", isDirectory: true),
            withIntermediateDirectories: true
        )

        let masterKey = try VaultCrypto.generateMasterKey()

        try VaultCrypto.wrapMasterKey(masterKey, password: password)
            .write(to: url.appendingPathComponent("masterkey.vaultx"))

        let manifest = VaultManifest(version: 2, name: "Legacy", createdAt: Date())

        try VaultCrypto.encrypt(
            try JSONEncoder().encode(manifest),
            using: masterKey
        )
        .write(to: url.appendingPathComponent("vault.manifest"))

        try VaultCrypto.encrypt(Data("ciao".utf8), using: masterKey)
            .write(to: url.appendingPathComponent("data/nota.txt.vltx"))

        try VaultCrypto.encrypt(Data("contratto".utf8), using: masterKey)
            .write(to: url.appendingPathComponent("data/Documenti/contratto.pdf.vltx"))

        return url
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

    // MARK: - Tests

    func testLegacyVaultIsDetectedAndBlockedUntilMigrated() throws {

        let url = try makeLegacyVault()

        let session = try store.unlockVault(at: url, password: password)

        XCTAssertTrue(session.isLegacy)

        XCTAssertThrowsError(try session.items(in: session.rootDirectory))

        session.lock()
    }

    func testMigrationConvertsStructureNamesAndContents() throws {

        let url = try makeLegacyVault()

        let session = try store.unlockVault(at: url, password: password)

        var reported: [(Int, Int)] = []

        try session.migrateFromLegacy { done, total in
            reported.append((done, total))
        }

        XCTAssertFalse(session.isLegacy)
        XCTAssertEqual(reported.last?.0, 2)
        XCTAssertEqual(reported.last?.1, 2)

        // struttura e nomi
        let root = try session.items(in: session.rootDirectory)

        XCTAssertEqual(root.map(\.name).sorted(), ["Documenti", "nota.txt"])

        let folder = try XCTUnwrap(root.first { $0.isFolder })

        XCTAssertEqual(
            try session.items(in: folder.url).map(\.name),
            ["contratto.pdf"]
        )

        // contenuti
        let note = try XCTUnwrap(root.first { !$0.isFolder })
        let plain = try session.decryptToTemporaryFile(note.url)

        XCTAssertEqual(try String(contentsOf: plain, encoding: .utf8), "ciao")

        // il vecchio albero (nomi in chiaro) è sparito
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: session.legacyDataDirectory.path)
        )

        for path in allFilePaths(in: url) {

            let lower = path.lowercased()

            XCTAssertFalse(lower.contains("nota"), path)
            XCTAssertFalse(lower.contains("contratto"), path)
            XCTAssertFalse(lower.contains("documenti"), path)
        }

        session.lock()

        // riaprendo, il vault è già v3 e il contenuto è lo stesso
        let reopened = try store.unlockVault(at: url, password: password)

        XCTAssertFalse(reopened.isLegacy)

        XCTAssertEqual(
            try reopened.items(in: reopened.rootDirectory).map(\.name).sorted(),
            ["Documenti", "nota.txt"]
        )

        reopened.lock()
    }

    func testFailedMigrationLeavesLegacyVaultUntouched() throws {

        let url = try makeLegacyVault()

        // un file rovinato
        let broken = url.appendingPathComponent("data/Documenti/contratto.pdf.vltx")

        var bytes = try Data(contentsOf: broken)
        bytes[bytes.count - 1] ^= 0x01
        try bytes.write(to: broken)

        let session = try store.unlockVault(at: url, password: password)

        XCTAssertThrowsError(try session.migrateFromLegacy())

        // resta nel vecchio formato, nulla è stato cancellato
        XCTAssertTrue(session.isLegacy)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: session.legacyDataDirectory.path)
        )

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: url.appendingPathComponent("index.vaultx").path
            )
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: session.contentDirectory.path)
        )

        session.lock()
    }

    func testNewVaultsAreCreatedInV3Format() throws {

        let url = try store.createVault(named: "Nuovo", password: password)

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: url.appendingPathComponent("index.vaultx").path
            )
        )

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: url.appendingPathComponent("data").path
            )
        )

        let session = try store.unlockVault(at: url, password: password)

        XCTAssertFalse(session.isLegacy)
        XCTAssertTrue(try session.items(in: session.rootDirectory).isEmpty)

        session.lock()
    }
}
