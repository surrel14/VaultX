import SwiftUI

/// Chiavi e valori di default delle impostazioni (salvate in UserDefaults).
enum AppSettings {

    /// Secondi in background prima del blocco: 0 = subito, -1 = mai.
    static let backgroundLockKey = "autoLock.backgroundSeconds"

    /// Secondi di inattività prima del blocco: 0 = mai.
    static let inactivityLockKey = "autoLock.inactivitySeconds"

    static let defaultBackgroundLockSeconds = 0
    static let defaultInactivityLockSeconds = 300
}

struct SettingsView: View {

    @Environment(\.dismiss)
    private var dismiss

    @AppStorage(AppSettings.backgroundLockKey)
    private var backgroundLockSeconds = AppSettings.defaultBackgroundLockSeconds

    @AppStorage(AppSettings.inactivityLockKey)
    private var inactivityLockSeconds = AppSettings.defaultInactivityLockSeconds

    var body: some View {

        NavigationStack {

            Form {

                Section {

                    Picker(
                        "Quando l'app va in background",
                        selection: $backgroundLockSeconds
                    ) {
                        Text("Subito").tag(0)
                        Text("Dopo 1 minuto").tag(60)
                        Text("Dopo 5 minuti").tag(300)
                        Text("Mai").tag(-1)
                    }

                    Picker(
                        "Dopo inattività",
                        selection: $inactivityLockSeconds
                    ) {
                        Text("Mai").tag(0)
                        Text("30 secondi").tag(30)
                        Text("1 minuto").tag(60)
                        Text("2 minuti").tag(120)
                        Text("5 minuti").tag(300)
                        Text("10 minuti").tag(600)
                    }

                } header: {
                    Text("Blocco automatico")
                } footer: {
                    Text("Al blocco la chiave viene cancellata dalla memoria e le copie temporanee dei file aperti vengono eliminate. Il timer di inattività si ferma mentre sono aperti anteprime, condivisione o selezione file.")
                }

                Section {

                    LabeledContent(
                        "Versione",
                        value: appVersion
                    )
                }
            }
            .navigationTitle("Impostazioni")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var appVersion: String {

        let info = Bundle.main.infoDictionary

        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"

        return "\(version) (\(build))"
    }
}
