import SwiftUI

@main
struct VaultXApp: App {
    init() {
        // Elimina eventuali copie in chiaro rimaste da sessioni precedenti.
        VaultSession.removeTemporaryFiles()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
