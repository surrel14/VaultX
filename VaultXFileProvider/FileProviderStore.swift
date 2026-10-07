import FileProvider
import Foundation
import UniformTypeIdentifiers

final class FileProviderStore {
    private let fm = FileManager.default
    private let root: URL

    init() {
        guard let container = fm.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.example.VaultX"
        ) else {
            fatalError("Unable to access the App Group container.")
        }

        root = container.appendingPathComponent(
            "FileProviderStorage",
            isDirectory: true
        )

        try? fm.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    func url(
        for identifier: NSFileProviderItemIdentifier
    ) -> URL? {
        if identifier == .rootContainer {
            return root
        }

        let path = identifier.rawValue

        guard !path.isEmpty,
              !path.contains(".."),
              !path.hasPrefix("/") else {
            return nil
        }

        return root.appendingPathComponent(path)
    }

    func identifier(
        for url: URL
    ) -> NSFileProviderItemIdentifier? {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path

        guard filePath == rootPath ||
              filePath.hasPrefix(rootPath + "/") else {
            return nil
        }

        let relative = String(
            filePath.dropFirst(rootPath.count)
        ).trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )

        if relative.isEmpty {
            return .rootContainer
        }

        return NSFileProviderItemIdentifier(relative)
    }

    func item(
        for identifier: NSFileProviderItemIdentifier
    ) -> FileProviderItem? {
        guard let url = url(for: identifier) else {
            return nil
        }

        guard fm.fileExists(atPath: url.path) else {
            return nil
        }

        return FileProviderItem(
            identifier: identifier,
            url: url,
            root: root
        )
    }

    func children(
        of identifier: NSFileProviderItemIdentifier
    ) -> [FileProviderItem] {
        guard let parent = url(for: identifier) else {
            return []
        }

        guard let urls = try? fm.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .fileSizeKey,
                .contentModificationDateKey,
                .contentTypeKey
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls.compactMap { child in
            guard let childIdentifier = self.identifier(for: child) else {
                return nil
            }

            return FileProviderItem(
                identifier: childIdentifier,
                url: child,
                root: root
            )
        }
    }
}

final class FileProviderItem: NSObject, NSFileProviderItem {
    let identifier: NSFileProviderItemIdentifier
    let url: URL

    init(
        identifier: NSFileProviderItemIdentifier,
        url: URL,
        root: URL
    ) {
        self.identifier = identifier
        self.url = url
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        identifier
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        if identifier == .rootContainer {
            return .rootContainer
        }

        let components = identifier.rawValue.split(separator: "/")

        guard components.count > 1 else {
            return .rootContainer
        }

        let parent = components.dropLast().joined(separator: "/")

        return NSFileProviderItemIdentifier(parent)
    }

    var filename: String {
        url.lastPathComponent
    }

    var typeIdentifier: String {
        guard let contentType = try? url.resourceValues(
            forKeys: [.contentTypeKey]
        ).contentType else {
            return UTType.data.identifier
        }

        return contentType.identifier
    }

    var capabilities: NSFileProviderItemCapabilities {
        [
            .allowsReading,
            .allowsWriting,
            .allowsRenaming,
            .allowsDeleting,
            .allowsReparenting
        ]
    }

    var documentSize: NSNumber? {
        guard let fileSize = try? url.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize else {
            return nil
        }

        return NSNumber(value: fileSize)
    }

    var contentModificationDate: Date? {
        guard let date = try? url.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate else {
            return nil
        }

        return date
    }
}
