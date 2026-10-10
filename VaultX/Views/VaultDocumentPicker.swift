import SwiftUI
import UIKit
import UniformTypeIdentifiers

// ============================================================
// MARK: - Document Picker
// ============================================================

struct VaultDocumentPicker:
    UIViewControllerRepresentable {

    let onPick:
        ([URL]) -> Void

    let onCancel:
        () -> Void

    /// `true`: il selettore consegna una copia temporanea (comodo per file piccoli).
    /// `false`: consegna l'URL originale (security-scoped), senza duplicare file enormi.
    var asCopy: Bool = true

    var allowsMultipleSelection: Bool = true


    func makeCoordinator()
        -> Coordinator {

        Coordinator(
            onPick:
                onPick,
            onCancel:
                onCancel
        )
    }


    func makeUIViewController(
        context:
            Context
    ) -> UIDocumentPickerViewController {

        let picker =
            UIDocumentPickerViewController(
                forOpeningContentTypes:
                    [
                        UTType.item
                    ],
                asCopy:
                    asCopy
            )

        picker.allowsMultipleSelection =
            allowsMultipleSelection

        picker.delegate =
            context.coordinator

        return picker
    }


    func updateUIViewController(
        _ uiViewController:
            UIDocumentPickerViewController,
        context:
            Context
    ) {
        // Nessun aggiornamento necessario.
    }


    final class Coordinator:
        NSObject,
        UIDocumentPickerDelegate {

        let onPick:
            ([URL]) -> Void

        let onCancel:
            () -> Void


        init(
            onPick:
                @escaping ([URL]) -> Void,
            onCancel:
                @escaping () -> Void
        ) {

            self.onPick =
                onPick

            self.onCancel =
                onCancel

            super.init()
        }


        func documentPicker(
            _ controller:
                UIDocumentPickerViewController,
            didPickDocumentsAt urls:
                [URL]
        ) {

            DispatchQueue.main.async {

                self.onPick(
                    urls
                )
            }
        }


        func documentPickerWasCancelled(
            _ controller:
                UIDocumentPickerViewController
        ) {

            DispatchQueue.main.async {

                self.onCancel()
            }
        }
    }
}
