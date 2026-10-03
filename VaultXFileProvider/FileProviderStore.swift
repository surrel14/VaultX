import FileProvider
import Foundation
import UniformTypeIdentifiers

final class FileProviderStore {
    private let fm = FileManager.default
    private let root: URL

    init() {
        root = fm.containerURL(forSecurityApplicationGroupIdentifier: "group.com.example.VaultX")!
            .appendingPathComponent("FileProviderStorage", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func url(for identifier: NSFileProviderItemIdentifier) -> URL? {
        if identifier == .rootContainer {
            return root
        }
        let path = identifier.rawValue
        guard !path.contains("..") else { return nil }
        return root.appendingPathComponent(path)
    }

    func identifier(for url: URL) -> NSFileProviderItemIdentifier? {
        guard url.path.hasPrefix(root.path) else { return nil }
        let relative = url.path.dropFirst(root.path.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? .rootContainer : NSFileProviderItemIdentifier(String(relative))
    }

    func item(for identifier: NSFileProviderItemIdentifier) -> FileProviderItem? {
        guard let url = url(for: identifier) else { return nil }
        guard fm.fileExists(atPath: url.path) else { return nil }
        return FileProviderItem(identifier: identifier, url: url, root: root)
    }

    func children(of identifier: NSFileProviderItemIdentifier) -> [FileProviderItem] {
        guard let parent = url(for: identifier),
              let urls = try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else {
            return []
        }
        return urls.compactMap { child in
            guard let id = self.identifier(for: child) else { return nil }
            return FileProviderItem(identifier: id, url: child, root: root)
        }
    }
}

final class FileProviderItem: NSObject, NSFileProviderItem {
    let identifier: NSFileProviderItemIdentifier
    let url: URL

    init(identifier: NSFileProviderItemIdentifier, url: URL, root: URL) {
        self.identifier = identifier
        self.url = url
    }

    var itemIdentifier: NSFileProviderItemIdentifier { identifier }
    var parentItemIdentifier: NSFileProviderItemIdentifier {
        identifier == .rootContainer ? .rootContainer : NSFileProviderItemIdentifier(
            identifier.rawValue.split(separator: "/").dropLast().joined(separator: "/")
        )
    }
    var filename: String { url.lastPathComponent }
    var typeIdentifier: String {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier) ?? UTType.data.identifier
    }
    var capabilities: NSFileProviderItemCapabilities {
        [.allowsReading, .allowsWriting, .allowsRenaming, .allowsDeleting, .allowsReparenting]
    }
    var documentSize: NSNumber? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              let size else { return nil }
        return NSNumber(value: size)
    }
    var contentModificationDate: Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
