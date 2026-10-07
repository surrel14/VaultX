import FileProvider
import Foundation

final class FileProviderExtension: NSFileProviderExtension {
    private let store = FileProviderStore()

    override func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier
    ) throws -> NSFileProviderEnumerator {
        return FileProviderEnumerator(
            containerItemIdentifier: containerItemIdentifier,
            store: store
        )
    }

    override func item(
        for identifier: NSFileProviderItemIdentifier
    ) throws -> NSFileProviderItem {
        guard let item = store.item(for: identifier) else {
            throw NSFileProviderError(.noSuchItem)
        }

        return item
    }

    override func urlForItem(
        withPersistentIdentifier identifier: NSFileProviderItemIdentifier
    ) -> URL? {
        return store.url(for: identifier)
    }

    override func persistentIdentifierForItem(
        at url: URL
    ) -> NSFileProviderItemIdentifier? {
        return store.identifier(for: url)
    }

    override func providePlaceholder(
        at url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let placeholder = NSFileProviderManager.placeholderURL(for: url)

        do {
            try FileManager.default.createDirectory(
                at: placeholder.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    override func startProvidingItem(
        at url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        completionHandler(nil)
    }

    override func stopProvidingItem(at url: URL) {
        // MVP: local-only provider, so there is no remote download to stop.
    }
}
