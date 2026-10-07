import Foundation
import LocalAuthentication

/// Informazioni sulla biometria disponibile (Face ID / Touch ID).
/// Lo sblocco vero e proprio avviene tramite il Keychain (vedi `KeychainStore`):
/// è il sistema a imporre la biometria quando si legge la chiave.
final class BiometricAuth {

    static let shared = BiometricAuth()

    private init() {}

    enum Kind {
        case none
        case faceID
        case touchID
    }

    var kind: Kind {

        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &error
        ) else {
            return .none
        }

        switch context.biometryType {
        case .faceID:
            return .faceID
        case .touchID:
            return .touchID
        default:
            return .none
        }
    }

    var isAvailable: Bool {
        kind != .none
    }

    var title: String {

        switch kind {
        case .faceID:
            return "Face ID"
        case .touchID:
            return "Touch ID"
        case .none:
            return "Biometria"
        }
    }

    var systemImage: String {

        switch kind {
        case .faceID:
            return "faceid"
        case .touchID:
            return "touchid"
        case .none:
            return "lock"
        }
    }
}
