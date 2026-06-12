import Foundation

struct Note: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var body: String
    var tags: [String] = []
    var updatedAt: Date = Date()
    var lastClaudeModifiedAt: Date? = nil
    var projectSlug: String

    var filename: String {
        title.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.union(.init(charactersIn: "-")).contains($0) }
            .reduce("") { $0 + String($1) }
            + ".md"
    }

    func markdownFileContent() -> String {
        let formatter = ISO8601DateFormatter()
        let tagsStr = tags.isEmpty ? "[]" : "[\(tags.joined(separator: ", "))]"
        var front = """
        ---
        id: \(id.uuidString)
        title: \(title)
        tags: \(tagsStr)
        updatedAt: \(formatter.string(from: updatedAt))
        """
        if let claude = lastClaudeModifiedAt {
            front += "\nlastClaudeModifiedAt: \(formatter.string(from: claude))"
        }
        front += "\n---"
        return front + "\n\n\(body)"
    }
}
