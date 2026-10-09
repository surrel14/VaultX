import Foundation

/// Nodo dell'indice: un file o una cartella del vault.
/// Su disco i file si chiamano `<id>.vltx` e stanno tutti in `files/` (struttura piatta):
/// nomi e cartelle esistono solo dentro l'indice, che è cifrato.
struct VaultNode: Codable, Identifiable, Hashable {

    let id: UUID

    /// `nil` = radice del vault.
    var parentID: UUID?

    var name: String
    var isFolder: Bool

    /// Dimensione del contenuto in chiaro (0 per le cartelle).
    var size: Int64

    var created: Date
    var modified: Date
}

/// Indice del vault v3: l'unico posto dove vivono nomi e struttura.
struct VaultIndex {

    var nodes: [UUID: VaultNode] = [:]

    init() {}

    // MARK: - Serialization

    private struct FileRepresentation: Codable {
        var version: Int
        var nodes: [VaultNode]
    }

    private static func makeEncoder() -> JSONEncoder {

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return decoder
    }

    func serialized() throws -> Data {

        try Self.makeEncoder().encode(
            FileRepresentation(version: 1, nodes: Array(nodes.values))
        )
    }

    init(serialized data: Data) throws {

        let file = try Self.makeDecoder().decode(
            FileRepresentation.self,
            from: data
        )

        for node in file.nodes {
            nodes[node.id] = node
        }

        repairStructure()
    }

    /// Un indice danneggiato non deve far sparire i file: i nodi senza un
    /// genitore valido (cartella esistente) vengono riportati nella radice.
    private mutating func repairStructure() {

        for node in nodes.values {

            guard let parentID = node.parentID else {
                continue
            }

            if let parent = nodes[parentID], parent.isFolder, parentID != node.id {
                continue
            }

            nodes[node.id]?.parentID = nil
        }

        // Cicli (A dentro B dentro A): si spezzano riportando il nodo nella radice.
        for node in nodes.values where isInCycle(node.id) {
            nodes[node.id]?.parentID = nil
        }
    }

    private func isInCycle(_ id: UUID) -> Bool {

        var visited: Set<UUID> = [id]
        var current = nodes[id]?.parentID

        while let parent = current {

            if visited.contains(parent) {
                return true
            }

            visited.insert(parent)
            current = nodes[parent]?.parentID
        }

        return false
    }

    // MARK: - Queries

    func children(of parent: UUID?) -> [VaultNode] {
        nodes.values.filter { $0.parentID == parent }
    }

    /// `true` se `id` sta (a qualsiasi profondità) dentro `ancestor`.
    func isDescendant(_ id: UUID, of ancestor: UUID) -> Bool {

        var current = nodes[id]?.parentID
        var steps = 0

        while let parent = current, steps <= nodes.count {

            if parent == ancestor {
                return true
            }

            current = nodes[parent]?.parentID
            steps += 1
        }

        return false
    }

    /// Il nodo e tutti i suoi discendenti.
    func subtree(of id: UUID) -> [UUID] {

        var result: [UUID] = []
        var stack = [id]

        while let next = stack.popLast() {

            result.append(next)

            for child in children(of: next) {
                stack.append(child.id)
            }
        }

        return result
    }

    func nameExists(
        _ name: String,
        in parent: UUID?,
        excluding excluded: UUID? = nil
    ) -> Bool {

        children(of: parent).contains { node in

            if node.id == excluded {
                return false
            }

            return node.name.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    /// "foto.jpg" -> "foto (1).jpg" se esiste già.
    func uniqueName(
        for name: String,
        isFolder: Bool,
        in parent: UUID?
    ) -> String {

        guard nameExists(name, in: parent) else {
            return name
        }

        let nsName = name as NSString
        let ext = isFolder ? "" : nsName.pathExtension
        let base = isFolder ? name : nsName.deletingPathExtension

        var counter = 1

        while true {

            let candidate = ext.isEmpty
                ? "\(base) (\(counter))"
                : "\(base) (\(counter)).\(ext)"

            if !nameExists(candidate, in: parent) {
                return candidate
            }

            counter += 1
        }
    }
}
