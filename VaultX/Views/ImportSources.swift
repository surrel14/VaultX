import SwiftUI
import UIKit
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers

// MARK: - Photos

/// File ricevuto dal selettore Foto: copiato in una cartella temporanea
/// (VaultXImport/<uuid>/<nome>) che viene eliminata dopo la cifratura.
struct PickedFile: Transferable {

    let url: URL

    static var transferRepresentation: some TransferRepresentation {

        FileRepresentation(importedContentType: .item) { received in

            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("VaultXImport", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)

            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true
            )

            let destination = folder.appendingPathComponent(
                ImportNaming.friendlyName(for: received.file.lastPathComponent)
            )

            try FileManager.default.copyItem(
                at: received.file,
                to: destination
            )

            return PickedFile(url: destination)
        }
    }
}

enum ImportNaming {

    private static func timestamp() -> String {

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"

        return formatter.string(from: Date())
    }

    /// Se il sistema ci dà un nome "tecnico" (UUID) lo sostituiamo con "Foto <data>".
    static func friendlyName(for original: String) -> String {

        let base = (original as NSString).deletingPathExtension
        let ext = (original as NSString).pathExtension

        guard UUID(uuidString: base) != nil else {
            return original
        }

        let name = "Foto \(timestamp())"

        return ext.isEmpty ? name : "\(name).\(ext)"
    }

    /// Salva una foto scattata con la fotocamera in un JPEG temporaneo.
    static func writeTemporaryPhoto(_ image: UIImage) throws -> URL {

        guard let data = image.jpegData(compressionQuality: 0.92) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultXImport", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )

        let url = folder.appendingPathComponent("Foto \(timestamp()).jpg")

        try data.write(to: url, options: [.atomic, .completeFileProtection])

        return url
    }
}

// MARK: - Camera

struct CameraPicker: UIViewControllerRepresentable {

    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void

    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    /// Senza `NSCameraUsageDescription` in Info.plist iOS chiude l'app appena si apre la fotocamera.
    static var hasUsageDescription: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {

        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator

        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIImagePickerController,
        context: Context
    ) {
        // Nessun aggiornamento necessario.
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {

        let onCapture: (UIImage) -> Void
        let onCancel: () -> Void

        init(
            onCapture: @escaping (UIImage) -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.onCapture = onCapture
            self.onCancel = onCancel
            super.init()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {

            if let image = info[.originalImage] as? UIImage {
                onCapture(image)
            } else {
                onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}
