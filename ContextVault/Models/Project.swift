import Foundation

struct Project: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var rootPath: String
    var createdAt: Date = Date()

    var slug: String {
        name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.union(.init(charactersIn: "-")).contains($0) }
            .reduce("") { $0 + String($1) }
    }

    var notesDirectory: URL {
        VaultManager.vaultRoot
            .appendingPathComponent(slug)
            .appendingPathComponent("notes")
    }
}
