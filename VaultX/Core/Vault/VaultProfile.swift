import Foundation

/// Profilo di un vault: aspetto e descrizione mostrati nell'elenco.
///
/// Si salva in `profile.json` dentro la cartella del vault ed è **in chiaro** (serve a
/// mostrare icona e colore anche a vault bloccato): niente di sensibile va scritto nella descrizione.
struct VaultProfile: Codable, Equatable {

    /// Nome di un simbolo SF Symbols.
    var icon: String

    /// Chiave di `VaultProfile.colorKeys`.
    var color: String

    /// Descrizione breve (facoltativa).
    var summary: String

    static let `default` = VaultProfile(icon: "lock.fill", color: "blue", summary: "")

    static let icons: [String] = [
        "lock.fill", "person.fill", "briefcase.fill", "doc.text.fill",
        "folder.fill", "photo.fill", "creditcard.fill", "heart.fill",
        "house.fill", "graduationcap.fill", "key.fill", "star.fill",
        "airplane", "cart.fill", "banknote.fill", "cross.case.fill"
    ]

    static let colorKeys: [String] = [
        "blue", "indigo", "purple", "pink", "red",
        "orange", "yellow", "green", "teal", "gray"
    ]

    /// Modelli di partenza.
    enum Preset: String, CaseIterable, Identifiable {

        case personal
        case work
        case documents
        case custom

        var id: String { rawValue }

        var title: String {

            switch self {
            case .personal: return "Personale"
            case .work: return "Lavoro"
            case .documents: return "Documenti"
            case .custom: return "Personalizzato"
            }
        }

        var profile: VaultProfile {

            switch self {

            case .personal:
                return VaultProfile(
                    icon: "person.fill",
                    color: "blue",
                    summary: "Foto, note e cose personali"
                )

            case .work:
                return VaultProfile(
                    icon: "briefcase.fill",
                    color: "orange",
                    summary: "File di lavoro"
                )

            case .documents:
                return VaultProfile(
                    icon: "doc.text.fill",
                    color: "green",
                    summary: "Documenti e contratti"
                )

            case .custom:
                return .default
            }
        }
    }
}

/// Informazioni mostrate nell'elenco dei vault.
struct VaultListInfo {

    var profile: VaultProfile = .default

    /// Spazio occupato su disco (cifrato). `nil` finché non è stato calcolato.
    var sizeBytes: Int64?

    /// Ultimo sblocco riuscito su questo dispositivo.
    var lastAccess: Date?

    /// Tentativi di sblocco falliti dall'ultimo sblocco riuscito.
    var failedAttempts: Int = 0
}
