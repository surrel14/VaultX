import FileProvider
import Foundation

final class FileProviderExtension: NSFileProviderExtension {
    private let store = FileProviderStore()

    override func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier) -> NSFileProviderEnumerator? {
        FileProviderEnumerator(containerItemIdentifier: containerItemIdentifier, store: store)
    }

    override func item(for identifier: NSFileProviderItemIdentifier) -> NSFileProviderItem? {
        store.item(for: identifier)
    }

    override func urlForItem(withPersistentIdentifier identifier: NSFileProviderItemIdentifier) -> URL? {
        store.url(for: identifier)
    }

    override func persistentIdentifierForItem(at url: URL) -> NSFileProviderItemIdentifier? {
        store.identifier(for: url)
    }

    override func providePlaceholder(at url: URL, completionHandler: @escaping (Error?) -> Void) {
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

    override func startProvidingItem(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        completionHandler(nil)
    }

    override func stopProvidingItem(at url: URL) {
        // MVP: local-only provider, so there is no remote download to stop.
    }
}
