import Foundation
import Observation

@Observable
final class VaultManager {
    static let vaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".contextvault")

    private(set) var projects: [Project] = []
    private(set) var lastModified: Date = Date()

    init() {
        createVaultRootIfNeeded()
        Task.detached(priority: .userInitiated) {
            let loaded = Self.readProjectsFromDisk()
            await MainActor.run { self.projects = loaded }
        }
    }

    // MARK: - Projects

    func loadProjects() {
        Task.detached(priority: .userInitiated) {
            let loaded = Self.readProjectsFromDisk()
            await MainActor.run { self.projects = loaded }
        }
    }

    private static func readProjectsFromDisk() -> [Project] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: vaultRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return dirs
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap { dir in
                let url = dir.appendingPathComponent(".project.json")
                guard let data = try? Data(contentsOf: url),
                      let project = try? decoder.decode(Project.self, from: data)
                else { return nil }
                return project
            }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    func addProject(_ project: Project) throws {
        let notesDir = Self.vaultRoot
            .appendingPathComponent(project.slug)
            .appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(project)
        try data.write(to: Self.vaultRoot.appendingPathComponent(project.slug).appendingPathComponent(".project.json"))

        if !projects.contains(where: { $0.id == project.id }) {
            projects.append(project)
            projects.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
        lastModified = Date()
    }

    func removeProject(_ project: Project) throws {
        try FileManager.default.removeItem(at: Self.vaultRoot.appendingPathComponent(project.slug))
        projects.removeAll { $0.id == project.id }
        lastModified = Date()
    }

    func project(forPath path: String) -> Project? {
        let normalized = path.hasSuffix("/") ? path : path + "/"
        return projects.first {
            let root = $0.rootPath.hasSuffix("/") ? $0.rootPath : $0.rootPath + "/"
            return normalized.hasPrefix(root) || normalized == root
        }
    }

    // MARK: - Notes

    // Cheap count: directory listing only, no file reads.
    func noteCount(for project: Project) -> Int {
        _ = lastModified
        return (try? FileManager.default.contentsOfDirectory(
            at: project.notesDirectory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ).filter { $0.pathExtension == "md" }.count) ?? 0
    }

    func notes(for project: Project) -> [Note] {
        _ = lastModified
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: project.notesDirectory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [] }

        return files
            .filter { $0.pathExtension == "md" }
            .compactMap { readNote(at: $0, projectSlug: project.slug) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func readNote(titled title: String, in project: Project) -> Note? {
        let slug = makeSlug(title)
        return readNote(at: project.notesDirectory.appendingPathComponent("\(slug).md"), projectSlug: project.slug)
    }

    func writeNote(_ note: Note, to project: Project) throws {
        try FileManager.default.createDirectory(at: project.notesDirectory, withIntermediateDirectories: true)
        var updated = note
        updated.updatedAt = Date()
        try updated.markdownFileContent().write(to: project.notesDirectory.appendingPathComponent(note.filename), atomically: true, encoding: .utf8)
        lastModified = Date()
    }

    func deleteNote(_ note: Note, from project: Project) throws {
        try FileManager.default.removeItem(at: project.notesDirectory.appendingPathComponent(note.filename))
        lastModified = Date()
    }

    func searchNotes(query: String, in project: Project) -> [Note] {
        guard !query.isEmpty else { return notes(for: project) }
        return notes(for: project).filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.body.localizedCaseInsensitiveContains(query) ||
            $0.tags.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    // MARK: - Private

    private func createVaultRootIfNeeded() {
        try? FileManager.default.createDirectory(at: Self.vaultRoot, withIntermediateDirectories: true)
    }

    private func readNote(at url: URL, projectSlug: String) -> Note? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parseMarkdown(content, filename: url.lastPathComponent, projectSlug: projectSlug)
    }

    private func parseMarkdown(_ content: String, filename: String, projectSlug: String) -> Note {
        let defaultTitle = filename
            .replacingOccurrences(of: ".md", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized

        var id = UUID()
        var title = defaultTitle
        var tags: [String] = []
        var updatedAt = Date()
        var lastClaudeModifiedAt: Date? = nil
        var body = content

        let lines = content.components(separatedBy: "\n")
        guard lines.first == "---" else { return Note(id: id, title: title, body: content, projectSlug: projectSlug) }

        var frontmatterEnd = 0
        var frontmatter: [String] = []
        for (i, line) in lines.dropFirst().enumerated() {
            if line == "---" { frontmatterEnd = i + 2; break }
            frontmatter.append(line)
        }

        for line in frontmatter {
            if line.hasPrefix("id: "), let parsed = UUID(uuidString: String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)) {
                id = parsed
            } else if line.hasPrefix("title: ") {
                title = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("tags: [") {
                let raw = String(line.dropFirst(7).dropLast())
                tags = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            } else if line.hasPrefix("updatedAt: ") {
                updatedAt = ISO8601DateFormatter().date(from: String(line.dropFirst(11))) ?? Date()
            } else if line.hasPrefix("lastClaudeModifiedAt: ") {
                lastClaudeModifiedAt = ISO8601DateFormatter().date(from: String(line.dropFirst(22)))
            }
        }

        if frontmatterEnd > 0, frontmatterEnd < lines.count {
            body = lines[frontmatterEnd...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return Note(id: id, title: title, body: body, tags: tags, updatedAt: updatedAt, lastClaudeModifiedAt: lastClaudeModifiedAt, projectSlug: projectSlug)
    }

    private func makeSlug(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.union(.init(charactersIn: "-")).contains($0) }
            .reduce("") { $0 + String($1) }
    }
}
