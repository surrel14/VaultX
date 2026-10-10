import XCTest
@testable import VaultX

final class SecurityLogTests: XCTestCase {

    private var fileURL: URL!

    override func setUpWithError() throws {

        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultXLogTests-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL)
    }

    func testRecordsEventsNewestFirstAndFiltersByVault() {

        let log = SecurityLog(fileURL: fileURL)

        log.record(.vaultCreated, vault: "A")
        log.record(.unlockSucceeded, vault: "B")
        log.record(.passwordChanged, vault: "A")

        XCTAssertEqual(log.events().map(\.kind), [.passwordChanged, .unlockSucceeded, .vaultCreated])
        XCTAssertEqual(log.events(vault: "A").map(\.kind), [.passwordChanged, .vaultCreated])
        XCTAssertEqual(log.events(vault: "B").count, 1)
    }

    func testFailedStreakRaisesSeverityAndSuccessResetsIt() {

        let log = SecurityLog(fileURL: fileURL)

        log.record(.unlockFailed, vault: "A")
        log.record(.unlockFailed, vault: "A")

        XCTAssertEqual(log.failedAttempts(vault: "A"), 2)
        XCTAssertEqual(log.events(vault: "A").first?.severity, .notice)

        log.record(.unlockFailed, vault: "A")

        XCTAssertEqual(log.failedAttempts(vault: "A"), 3)
        XCTAssertEqual(log.events(vault: "A").first?.severity, .warning)
        XCTAssertEqual(log.events(vault: "A").first?.detail, "Tentativo 3 consecutivo")

        // Altri vault non sono coinvolti.
        XCTAssertEqual(log.failedAttempts(vault: "B"), 0)

        log.record(.unlockSucceeded, vault: "A")

        XCTAssertEqual(log.failedAttempts(vault: "A"), 0)
    }

    func testSummary() {

        let log = SecurityLog(fileURL: fileURL)

        XCTAssertNil(log.summary(vault: "A").lastUnlock)

        log.record(.unlockSucceeded, vault: "A")
        log.record(.vaultExported, vault: "A")
        log.record(.vaultImported, vault: "A")
        log.record(.unlockFailed, vault: "A")

        let summary = log.summary(vault: "A")

        XCTAssertNotNil(summary.lastUnlock)
        XCTAssertNotNil(summary.lastExport)
        XCTAssertNotNil(summary.lastImport)
        XCTAssertEqual(summary.failedAttempts, 1)
    }

    func testIsPersistentAndCapped() {

        let log = SecurityLog(fileURL: fileURL, maxEvents: 5)

        for _ in 0 ..< 8 {
            log.record(.unlockSucceeded, vault: "A")
        }

        XCTAssertEqual(log.events().count, 5)

        // Un'altra istanza legge lo stesso file.
        let reopened = SecurityLog(fileURL: fileURL, maxEvents: 5)

        XCTAssertEqual(reopened.events().count, 5)
    }

    func testClear() {

        let log = SecurityLog(fileURL: fileURL)

        log.record(.vaultCreated, vault: "A")
        log.record(.vaultCreated, vault: "B")

        log.clear(vault: "A")

        XCTAssertEqual(log.events().map(\.vault), ["B"])

        log.clear()

        XCTAssertTrue(log.events().isEmpty)
    }

    func testSensitiveActionsAreNoticesOrWarnings() {

        XCTAssertEqual(SecurityLog.defaultSeverity(for: .unlockSucceeded), .info)
        XCTAssertEqual(SecurityLog.defaultSeverity(for: .vaultExported), .notice)
        XCTAssertEqual(SecurityLog.defaultSeverity(for: .passwordReset), .warning)
    }
}
