import Foundation

/// Evento del registro di sicurezza. Contiene solo metadati: mai password, chiavi,
/// nomi di file o contenuti dei documenti.
struct SecurityEvent: Codable, Identifiable, Equatable {

    enum Kind: String, Codable {

        case vaultCreated
        case unlockSucceeded
        case unlockFailed
        case passwordChanged
        case passwordReset
        case recoveryKeyCreated
        case recoveryKeyRemoved
        case biometricEnabled
        case biometricDisabled
        case vaultExported
        case vaultImported
        case vaultDuplicated
        case vaultDeleted
        case vaultMigrated
        case filesExported
        case filesDeleted
        case secureShareCreated
        case secureShareOpened
    }

    enum Severity: String, Codable {
        case info
        case notice
        case warning
    }

    let id: UUID
    let date: Date
    let vault: String
    let kind: Kind
    var detail: String?
    var severity: Severity
}

/// Registro di sicurezza locale (fuori dai vault, quindi disponibile anche a vault bloccato:
/// i tentativi falliti avvengono proprio quando il vault è chiuso).
final class SecurityLog: @unchecked Sendable {

    static let shared = SecurityLog(fileURL: SecurityLog.defaultFileURL)

    static var defaultFileURL: URL {

        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]

        return base
            .appendingPathComponent("VaultX", isDirectory: true)
            .appendingPathComponent("security-log.json")
    }

    private let fileURL: URL
    private let maxEvents: Int
    private let lock = NSLock()
    private var cache: [SecurityEvent]?

    init(fileURL: URL, maxEvents: Int = 500) {
        self.fileURL = fileURL
        self.maxEvents = maxEvents
    }

    // MARK: - Storage

    private func loadLocked() -> [SecurityEvent] {

        if let cache {
            return cache
        }

        var loaded: [SecurityEvent] = []

        if let data = try? Data(contentsOf: fileURL) {

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            loaded = (try? decoder.decode([SecurityEvent].self, from: data)) ?? []
        }

        cache = loaded

        return loaded
    }

    private func saveLocked(_ events: [SecurityEvent]) {

        cache = events

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(events) else {
            return
        }

        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try? data.write(
            to: fileURL,
            options: [.atomic, .completeFileProtection]
        )
    }

    // MARK: - Record

    /// Registra un evento. I tentativi falliti consecutivi alzano la gravità
    /// (3 o più = avviso).
    func record(
        _ kind: SecurityEvent.Kind,
        vault: String,
        detail: String? = nil,
        severity: SecurityEvent.Severity? = nil
    ) {

        lock.lock()
        defer { lock.unlock() }

        var events = loadLocked()

        var finalSeverity = severity ?? Self.defaultSeverity(for: kind)
        var finalDetail = detail

        if kind == .unlockFailed {

            let consecutive = Self.failedStreak(in: events, vault: vault) + 1

            finalDetail = "Tentativo \(consecutive) consecutivo"

            if consecutive >= 3 {
                finalSeverity = .warning
            }
        }

        events.append(
            SecurityEvent(
                id: UUID(),
                date: Date(),
                vault: vault,
                kind: kind,
                detail: finalDetail,
                severity: finalSeverity
            )
        )

        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }

        saveLocked(events)
    }

    static func defaultSeverity(for kind: SecurityEvent.Kind) -> SecurityEvent.Severity {

        switch kind {

        case .passwordReset:
            return .warning

        case .unlockFailed, .passwordChanged, .recoveryKeyCreated, .recoveryKeyRemoved,
             .vaultExported, .vaultDeleted, .filesExported, .filesDeleted,
             .vaultDuplicated, .secureShareCreated:
            return .notice

        default:
            return .info
        }
    }

    // MARK: - Query

    /// Dal più recente al più vecchio.
    func events(vault: String? = nil) -> [SecurityEvent] {

        lock.lock()
        defer { lock.unlock() }

        let all = loadLocked()

        let filtered = vault.map { name in
            all.filter { $0.vault == name }
        } ?? all

        return filtered.reversed()
    }

    func clear(vault: String? = nil) {

        lock.lock()
        defer { lock.unlock() }

        let events = loadLocked()

        if let vault {
            saveLocked(events.filter { $0.vault != vault })
        } else {
            saveLocked([])
        }
    }

    /// Tentativi falliti consecutivi dopo l'ultimo sblocco riuscito.
    func failedAttempts(vault: String) -> Int {

        lock.lock()
        defer { lock.unlock() }

        return Self.failedStreak(in: loadLocked(), vault: vault)
    }

    private static func failedStreak(
        in events: [SecurityEvent],
        vault: String
    ) -> Int {

        var streak = 0

        for event in events.reversed() where event.vault == vault {

            switch event.kind {

            case .unlockFailed:
                streak += 1

            case .unlockSucceeded:
                return streak

            default:
                continue
            }
        }

        return streak
    }

    struct Summary {
        var lastUnlock: Date?
        var lastExport: Date?
        var lastImport: Date?
        var failedAttempts: Int
    }

    func summary(vault: String) -> Summary {

        lock.lock()
        defer { lock.unlock() }

        let events = loadLocked().filter { $0.vault == vault }

        func last(_ kinds: Set<SecurityEvent.Kind>) -> Date? {
            events.last { kinds.contains($0.kind) }?.date
        }

        return Summary(
            lastUnlock: last([.unlockSucceeded]),
            lastExport: last([.vaultExported, .filesExported, .secureShareCreated]),
            lastImport: last([.vaultImported]),
            failedAttempts: Self.failedStreak(in: loadLocked(), vault: vault)
        )
    }
}
