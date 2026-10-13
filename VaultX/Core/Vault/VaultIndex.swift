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

    /// Data in cui il nodo è stato spostato nel Cestino; nil = elemento attivo.
    /// È opzionale per mantenere compatibilità con gli indici cifrati già esistenti.
    var trashedAt: Date? = nil

    /// Tag personalizzati salvati nell’indice cifrato. Opzionale per compatibilità
    /// con gli indici creati dalle versioni precedenti di VaultX.
    var tags: [String]? = nil
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

    /// `true` se il nodo o uno dei suoi antenati è nel Cestino.
    func isTrashed(_ id: UUID) -> Bool {
        nodes[id]?.trashedAt != nil || hasTrashedAncestor(of: id)
    }

    /// Controlla solo gli antenati, non il nodo stesso.
    func hasTrashedAncestor(of id: UUID) -> Bool {
        var current = nodes[id]?.parentID
        var visited = Set<UUID>()

        while let parentID = current, visited.insert(parentID).inserted {
            guard let parent = nodes[parentID] else {
                break
            }

            if parent.trashedAt != nil {
                return true
            }

            current = parent.parentID
        }

        return false
    }

    /// Figli utilizzabili nella normale navigazione. Gli elementi nel Cestino e
    /// quelli contenuti in una cartella nel Cestino restano nascosti.
    func visibleChildren(of parent: UUID?) -> [VaultNode] {
        if let parent, isTrashed(parent) {
            return []
        }

        return children(of: parent).filter { !isTrashed($0.id) }
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

        visibleChildren(of: parent).contains { node in

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
