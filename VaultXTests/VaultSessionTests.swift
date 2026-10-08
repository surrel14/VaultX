import XCTest
@testable import VaultX

final class VaultSessionTests: XCTestCase {

    private let password = "correct horse battery"

    private var tempRoot: URL!
    private var store: VaultStore!
    private var session: VaultSession!

    override func setUpWithError() throws {

        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "VaultXTests-\(UUID().uuidString)",
                isDirectory: true
            )

        store = VaultStore(rootURL: tempRoot.appendingPathComponent("Vaults"))

        let vaultURL = try store.createVault(
            named: "Test",
            password: password
        )

        session = try store.unlockVault(
            at: vaultURL,
            password: password
        )
    }

    override func tearDownWithError() throws {

        session.lock()

        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Helpers

    private func makeSourceFile(
        named name: String,
        contents: String = "contenuto di prova"
    ) throws -> URL {

        let directory = tempRoot.appendingPathComponent(
            "source",
            isDirectory: true
        )

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let url = directory.appendingPathComponent(name)

        try Data(contents.utf8).write(to: url)

        return url
    }

    // MARK: - Import / list

    func testImportKeepsExtensionAndListsOriginalName() throws {

        let source = try makeSourceFile(named: "foto.jpg")

        try session.importFile(at: source, into: session.rootDirectory)

        let items = try session.items(in: session.rootDirectory)

        XCTAssertEqual(items.map(\.name), ["foto.jpg"])
        XCTAssertFalse(items[0].isFolder)
        XCTAssertEqual(items[0].size, Int64("contenuto di prova".utf8.count))
    }

    func testDuplicateImportGetsUniqueName() throws {

        let source = try makeSourceFile(named: "foto.jpg")

        try session.importFile(at: source, into: session.rootDirectory)
        try session.importFile(at: source, into: session.rootDirectory)

        let names = try session.items(in: session.rootDirectory)
            .map(\.name)
            .sorted()

        XCTAssertEqual(names, ["foto (1).jpg", "foto.jpg"])
    }

    func testDecryptToTemporaryFileRestoresContents() throws {

        let source = try makeSourceFile(named: "nota.txt", contents: "ciao")

        try session.importFile(at: source, into: session.rootDirectory)

        let item = try XCTUnwrap(
            session.items(in: session.rootDirectory).first
        )

        let plain = try session.decryptToTemporaryFile(item.url)

        XCTAssertEqual(plain.lastPathComponent, "nota.txt")
        XCTAssertEqual(try String(contentsOf: plain, encoding: .utf8), "ciao")
    }

    // MARK: - Folders / rename / move / delete

    func testCreateFolderAndRejectDuplicates() throws {

        try session.createFolder(named: "Documenti", in: session.rootDirectory)

        XCTAssertThrowsError(
            try session.createFolder(named: "documenti", in: session.rootDirectory)
        )

        XCTAssertThrowsError(
            try session.createFolder(named: "a/b", in: session.rootDirectory)
        )
    }

    func testRenameFile() throws {

        let source = try makeSourceFile(named: "vecchio.txt")

        try session.importFile(at: source, into: session.rootDirectory)

        let item = try XCTUnwrap(
            session.items(in: session.rootDirectory).first
        )

        try session.renameItem(item, to: "nuovo.txt")

        let names = try session.items(in: session.rootDirectory).map(\.name)

        XCTAssertEqual(names, ["nuovo.txt"])
    }

    func testMoveFileIntoFolder() throws {

        let source = try makeSourceFile(named: "doc.txt")

        try session.importFile(at: source, into: session.rootDirectory)

        let folder = try session.createFolder(
            named: "Archivio",
            in: session.rootDirectory
        )

        let file = try XCTUnwrap(
            session.items(in: session.rootDirectory).first { !$0.isFolder }
        )

        try session.moveItem(file, to: folder)

        let inFolder = try session.items(in: folder).map(\.name)
        let inRoot = try session.items(in: session.rootDirectory).map(\.name)

        XCTAssertEqual(inFolder, ["doc.txt"])
        XCTAssertEqual(inRoot, ["Archivio"])
    }

    func testCannotMoveFolderIntoItself() throws {

        let parent = try session.createFolder(
            named: "A",
            in: session.rootDirectory
        )

        let child = try session.createFolder(named: "B", in: parent)

        let folderA = try XCTUnwrap(
            session.items(in: session.rootDirectory).first
        )

        XCTAssertFalse(session.canMove(folderA, to: parent))
        XCTAssertFalse(session.canMove(folderA, to: child))
        XCTAssertThrowsError(try session.moveItem(folderA, to: child))
    }

    func testDeleteFolderRemovesContents() throws {

        let folder = try session.createFolder(
            named: "Da eliminare",
            in: session.rootDirectory
        )

        let source = try makeSourceFile(named: "x.txt")

        try session.importFile(at: source, into: folder)

        let item = try XCTUnwrap(
            session.items(in: session.rootDirectory).first
        )

        try session.deleteItem(item)

        XCTAssertTrue(try session.items(in: session.rootDirectory).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    // MARK: - Bulk operations

    func testBulkMoveSkipsItemsAlreadyInDestination() throws {

        let folder = try session.createFolder(named: "Dest", in: session.rootDirectory)

        for name in ["a.txt", "b.txt"] {

            let source = try makeSourceFile(named: name)
            try session.importFile(at: source, into: session.rootDirectory)
        }

        let files = try session.items(in: session.rootDirectory).filter { !$0.isFolder }

        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(session.movableCount(files, to: folder), 2)

        let failures = session.moveItems(files, to: folder)

        XCTAssertTrue(failures.isEmpty)

        let moved = try session.items(in: folder).map(\.name).sorted()
        XCTAssertEqual(moved, ["a.txt", "b.txt"])
    }

    func testBulkDeleteIgnoresItemsInsideSelectedFolder() throws {

        let folder = try session.createFolder(named: "Cartella", in: session.rootDirectory)

        let source = try makeSourceFile(named: "dentro.txt")
        try session.importFile(at: source, into: folder)

        let child = try XCTUnwrap(session.items(in: folder).first)
        let parent = try XCTUnwrap(session.items(in: session.rootDirectory).first)

        // Cartella + file contenuto: non deve dare errori "file non trovato".
        let failures = session.deleteItems([child, parent])

        XCTAssertTrue(failures.isEmpty)
        XCTAssertTrue(try session.items(in: session.rootDirectory).isEmpty)
    }

    // MARK: - Lock / key management

    func testLockWipesKeyAndBlocksOperations() throws {

        XCTAssertFalse(session.isLocked)

        session.lock()

        XCTAssertTrue(session.isLocked)

        XCTAssertThrowsError(try session.masterKeyData())

        XCTAssertThrowsError(
            try session.items(in: session.rootDirectory)
        )

        let source = try makeSourceFile(named: "dopo-lock.txt")

        XCTAssertThrowsError(
            try session.importFile(at: source, into: session.rootDirectory)
        )
    }

    func testBiometricUnlockEnabledFlagIsOffByDefault() {

        XCTAssertFalse(
            store.isBiometricUnlockEnabled(for: session.vaultURL)
        )
    }
}
