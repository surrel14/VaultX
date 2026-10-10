import XCTest
import CryptoKit
@testable import VaultX

/// Esportazione / importazione / duplicazione dei vault e profili.
final class VaultPackageTests: XCTestCase {

    private let password = "correct horse battery"

    private var tempRoot: URL!
    private var vaultsRoot: URL!
    private var store: VaultStore!

    override func setUpWithError() throws {

        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "VaultXPackageTests-\(UUID().uuidString)",
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

    private func uniqueName(_ base: String) -> String {
        "\(base)-\(UUID().uuidString.prefix(8))"
    }

    /// Vault con un file ("nota.txt") e un profilo personalizzato.
    private func makeVault(named name: String) throws -> URL {

        let profile = VaultProfile(icon: "briefcase.fill", color: "orange", summary: "Lavoro")

        let url = try store.createVault(named: name, password: password, profile: profile)

        let session = try store.unlockVault(at: url, password: password)

        let source = tempRoot.appendingPathComponent("nota.txt")
        try Data("contenuto riservato".utf8).write(to: source)

        try session.importFile(at: source, into: session.rootDirectory)

        session.lock()

        return url
    }

    private func exportedPackage(of vault: URL) throws -> URL {

        let package = tempRoot.appendingPathComponent(
            "\(UUID().uuidString).\(VaultPackage.fileExtension)"
        )

        try store.exportVault(at: vault, to: package)

        return package
    }

    private func isPackageError(_ error: Error) -> Bool {
        error is VaultPackageError
    }

    private func be(_ value: UInt64, bytes count: Int) -> Data {

        Data(
            (0 ..< count).reversed().map {
                UInt8((value >> UInt64(8 * $0)) & 0xFF)
            }
        )
    }

    /// Costruisce a mano un pacchetto (per provare i controlli di sicurezza dell'importazione).
    private func craftPackage(_ entries: [(path: String, data: Data)]) throws -> URL {

        var out = Data("VXVAULT1".utf8)

        let header = try JSONSerialization.data(
            withJSONObject: [
                "format": 1,
                "name": "Costruito",
                "createdAt": "2026-01-01T00:00:00Z"
            ]
        )

        out.append(be(UInt64(header.count), bytes: 4))
        out.append(header)

        var overall = SHA256()

        for entry in entries {

            let path = Data(entry.path.utf8)
            let size = be(UInt64(entry.data.count), bytes: 8)

            out.append(0x01)
            out.append(be(UInt64(path.count), bytes: 2))
            out.append(path)
            out.append(size)
            out.append(entry.data)

            var hasher = SHA256()
            hasher.update(data: path)
            hasher.update(data: size)
            hasher.update(data: entry.data)

            let digest = Data(hasher.finalize())

            out.append(digest)
            overall.update(data: digest)
        }

        out.append(0x00)
        out.append(be(UInt64(entries.count), bytes: 4))
        out.append(Data(overall.finalize()))

        let url = tempRoot.appendingPathComponent("crafted-\(UUID().uuidString).vaultxpkg")

        try out.write(to: url)

        return url
    }

    private func stagingFolders() throws -> [String] {

        try FileManager.default
            .contentsOfDirectory(atPath: vaultsRoot.path)
            .filter { $0.hasPrefix(".import-") }
    }

    // MARK: - Export / import

    func testExportImportRoundTripKeepsEverything() throws {

        let name = uniqueName("Origine")
        let original = try makeVault(named: name)

        let package = try exportedPackage(of: original)

        let header = try VaultPackage.inspect(package)
        XCTAssertEqual(header.name, name)

        let imported = try store.importVaultPackage(from: package)

        // Mai sovrascrive: il nome è già usato, quindi viene aggiunto un numero.
        XCTAssertEqual(imported.lastPathComponent, "\(name) (2)")

        XCTAssertEqual(
            try store.vaults().map(\.lastPathComponent).sorted(),
            [name, "\(name) (2)"].sorted()
        )

        // Si apre con la stessa password e contiene lo stesso file.
        let session = try store.unlockVault(at: imported, password: password)

        let items = try session.items(in: session.rootDirectory)
        XCTAssertEqual(items.map(\.name), ["nota.txt"])

        let plain = try session.decryptToTemporaryFile(items[0].url)
        XCTAssertEqual(try String(contentsOf: plain, encoding: .utf8), "contenuto riservato")

        session.lock()

        // Anche il profilo viaggia con il vault.
        let profile = store.profile(for: imported)
        XCTAssertEqual(profile.icon, "briefcase.fill")
        XCTAssertEqual(profile.color, "orange")
        XCTAssertEqual(profile.summary, "Lavoro")

        // La password sbagliata continua a non funzionare.
        XCTAssertThrowsError(try store.unlockVault(at: imported, password: "wrong password"))
    }

    func testImportDetectsCorruptionAndLeavesNothingBehind() throws {

        let original = try makeVault(named: uniqueName("Corrotto"))

        let package = try exportedPackage(of: original)

        var bytes = try Data(contentsOf: package)

        // Un bit cambiato a metà del pacchetto.
        bytes[bytes.count / 2] ^= 0x01

        let broken = tempRoot.appendingPathComponent("rotto.vaultxpkg")
        try bytes.write(to: broken)

        let before = try store.vaults().count

        XCTAssertThrowsError(try store.importVaultPackage(from: broken))

        XCTAssertEqual(try store.vaults().count, before)
        XCTAssertTrue(try stagingFolders().isEmpty)
    }

    func testImportRejectsTruncatedPackage() throws {

        let original = try makeVault(named: uniqueName("Troncato"))

        let package = try exportedPackage(of: original)

        let bytes = try Data(contentsOf: package)

        let truncated = tempRoot.appendingPathComponent("troncato.vaultxpkg")
        try bytes.prefix(bytes.count - 40).write(to: truncated)

        XCTAssertThrowsError(try store.importVaultPackage(from: truncated))
        XCTAssertTrue(try stagingFolders().isEmpty)
    }

    func testImportRejectsFilesThatAreNotPackages() throws {

        let junk = tempRoot.appendingPathComponent("junk.vaultxpkg")
        try Data("non sono un pacchetto".utf8).write(to: junk)

        XCTAssertThrowsError(try store.importVaultPackage(from: junk)) { error in

            guard case VaultPackageError.notAPackage = error else {
                return XCTFail("\(error)")
            }
        }

        XCTAssertThrowsError(try VaultPackage.inspect(junk))
    }

    func testImportRejectsUnsafePaths() throws {

        let valid = Data("x".utf8)

        let paths = [
            "../evil.txt",
            "files/../../evil.txt",
            "/etc/passwd",
            "evil/file.txt",          // radice non prevista dal formato
            "files//double.vltx",
            "files/./dot.vltx"
        ]

        for path in paths {

            let package = try craftPackage([(path, valid)])

            XCTAssertThrowsError(try store.importVaultPackage(from: package), path) { error in
                XCTAssertTrue(self.isPackageError(error), "\(path): \(error)")
            }
        }

        XCTAssertTrue(try stagingFolders().isEmpty)

        // Nulla è finito fuori dalla cartella dei vault.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("evil.txt").path)
        )
    }

    func testImportRequiresACompleteVault() throws {

        // Un pacchetto valido ma senza masterkey/manifest non è un vault.
        let package = try craftPackage([("files/ABC.vltx", Data("x".utf8))])

        XCTAssertThrowsError(try store.importVaultPackage(from: package)) { error in

            guard case VaultPackageError.invalidVault = error else {
                return XCTFail("\(error)")
            }
        }

        XCTAssertTrue(try stagingFolders().isEmpty)
    }

    func testExportDoesNotIncludeTemporaryPartFiles() throws {

        let original = try makeVault(named: uniqueName("Part"))

        let stray = original
            .appendingPathComponent("files")
            .appendingPathComponent("\(UUID().uuidString).vltx.part")

        try Data("residuo".utf8).write(to: stray)

        let package = try exportedPackage(of: original)

        let imported = try store.importVaultPackage(from: package)

        let files = try FileManager.default.contentsOfDirectory(
            atPath: imported.appendingPathComponent("files").path
        )

        XCTAssertFalse(files.contains { $0.hasSuffix(".part") })
        XCTAssertEqual(files.count, 1)
    }

    // MARK: - Duplicate

    func testDuplicateVault() throws {

        let name = uniqueName("Da duplicare")
        let original = try makeVault(named: name)

        let first = try store.duplicateVault(at: original)
        let second = try store.duplicateVault(at: original)

        XCTAssertEqual(first.lastPathComponent, "\(name) (copia)")
        XCTAssertEqual(second.lastPathComponent, "\(name) (copia 2)")

        let session = try store.unlockVault(at: first, password: password)

        XCTAssertEqual(
            try session.items(in: session.rootDirectory).map(\.name),
            ["nota.txt"]
        )

        session.lock()
    }

    // MARK: - Profile & statistics

    func testProfileRoundTripAndSanitization() throws {

        let url = try store.createVault(
            named: uniqueName("Profilo"),
            password: password
        )

        // Predefinito.
        XCTAssertEqual(store.profile(for: url), .default)

        try store.saveProfile(
            VaultProfile(icon: "house.fill", color: "teal", summary: "  Casa  "),
            for: url
        )

        let saved = store.profile(for: url)

        XCTAssertEqual(saved.icon, "house.fill")
        XCTAssertEqual(saved.color, "teal")
        XCTAssertEqual(saved.summary, "Casa")

        // Valori non validi o troppo lunghi vengono ripuliti.
        try store.saveProfile(
            VaultProfile(
                icon: "non.esiste",
                color: "fucsia",
                summary: String(repeating: "a", count: 500)
            ),
            for: url
        )

        let cleaned = store.profile(for: url)

        XCTAssertEqual(cleaned.icon, VaultProfile.default.icon)
        XCTAssertEqual(cleaned.color, VaultProfile.default.color)
        XCTAssertEqual(cleaned.summary.count, 200)
    }

    func testDiskUsageAndLastAccess() throws {

        let url = try makeVault(named: uniqueName("Statistiche"))

        XCTAssertGreaterThan(store.diskUsage(of: url), 0)

        let session = try store.unlockVault(at: url, password: password)
        session.lock()

        let lastAccess = try XCTUnwrap(store.lastAccess(of: url))

        XCTAssertLessThan(abs(lastAccess.timeIntervalSinceNow), 60)
    }

    func testWrongPasswordIsLoggedAndSuccessResetsTheStreak() throws {

        let name = uniqueName("Registro")
        let url = try store.createVault(named: name, password: password)

        XCTAssertEqual(SecurityLog.shared.failedAttempts(vault: name), 0)

        XCTAssertThrowsError(try store.unlockVault(at: url, password: "wrong password"))
        XCTAssertThrowsError(try store.unlockVault(at: url, password: "wrong again!!"))

        XCTAssertEqual(SecurityLog.shared.failedAttempts(vault: name), 2)
        XCTAssertEqual(store.quickInfo(for: url).failedAttempts, 2)

        let session = try store.unlockVault(at: url, password: password)
        session.lock()

        XCTAssertEqual(SecurityLog.shared.failedAttempts(vault: name), 0)
    }
}
