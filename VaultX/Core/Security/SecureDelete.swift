import Foundation
import Security

/// Eliminazione "best effort" di file e cartelle: prima sovrascrive il contenuto
/// con dati casuali, poi rimuove il file.
///
/// Nota onesta: su APFS/flash (copy-on-write, wear leveling) la sovrascrittura
/// non garantisce la cancellazione fisica dei blocchi originali. La vera protezione
/// resta la cifratura: i file del vault sono illeggibili senza la master key.
enum SecureDelete {

    static func remove(at url: URL) throws {

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) else {
            return
        }

        if isDirectory.boolValue {

            let children = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: []
            )

            for child in children {
                try remove(at: child)
            }

        } else {

            // Se la sovrascrittura fallisce, eliminiamo comunque il file.
            try? overwrite(url)
        }

        try fileManager.removeItem(at: url)
    }

    private static func overwrite(_ url: URL) throws {

        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )

        guard let size = (attributes[.size] as? NSNumber)?.uint64Value,
              size > 0 else {
            return
        }

        let handle = try FileHandle(forWritingTo: url)

        defer {
            try? handle.close()
        }

        let chunkSize: UInt64 = 64 * 1024
        var remaining = size

        while remaining > 0 {

            let count = Int(min(chunkSize, remaining))
            var bytes = [UInt8](repeating: 0, count: count)

            let status = SecRandomCopyBytes(
                kSecRandomDefault,
                count,
                &bytes
            )

            guard status == errSecSuccess else {
                return
            }

            try handle.write(contentsOf: Data(bytes))

            remaining -= UInt64(count)
        }

        try handle.synchronize()
    }
}
