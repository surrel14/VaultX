import Foundation

/// Chiave di recupero: 32 byte casuali mostrati come testo base32
/// (alfabeto RFC 4648, senza 0/1/8/9) in gruppi da 4 caratteri.
enum RecoveryKey {

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    static func generate() throws -> Data {
        try VaultCrypto.randomBytes(count: VaultCrypto.recoveryKeyLength)
    }

    /// "ABCD-EFGH-IJKL-..." (13 gruppi per 32 byte).
    static func format(_ data: Data) -> String {

        var output = ""
        var buffer: UInt32 = 0
        var bits = 0

        for byte in data {

            buffer = (buffer << 8) | UInt32(byte)
            bits += 8

            while bits >= 5 {

                let index = Int((buffer >> UInt32(bits - 5)) & 0x1F)
                output.append(alphabet[index])
                bits -= 5
            }

            buffer &= (UInt32(1) << UInt32(bits)) - 1
        }

        if bits > 0 {

            let index = Int((buffer << UInt32(5 - bits)) & 0x1F)
            output.append(alphabet[index])
        }

        var grouped = ""

        for (position, character) in output.enumerated() {

            if position > 0, position % 4 == 0 {
                grouped.append("-")
            }

            grouped.append(character)
        }

        return grouped
    }

    /// Accetta maiuscole/minuscole, spazi e trattini. Restituisce `nil`
    /// se il testo non è una chiave valida.
    static func parse(_ text: String) -> Data? {

        var result = Data()
        var buffer: UInt32 = 0
        var bits = 0

        for character in text.uppercased() {

            if character == "-" || character.isWhitespace {
                continue
            }

            var symbol = character

            // Errori di battitura comuni: 0 -> O, 1 -> I
            if symbol == "0" { symbol = "O" }
            if symbol == "1" { symbol = "I" }

            guard let index = alphabet.firstIndex(of: symbol) else {
                return nil
            }

            buffer = (buffer << 5) | UInt32(index)
            bits += 5

            if bits >= 8 {

                result.append(UInt8((buffer >> UInt32(bits - 8)) & 0xFF))
                bits -= 8
                buffer &= (UInt32(1) << UInt32(bits)) - 1
            }
        }

        return result.count == VaultCrypto.recoveryKeyLength ? result : nil
    }
}
