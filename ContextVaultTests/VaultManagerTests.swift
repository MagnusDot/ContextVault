import Testing
import Foundation
@testable import ContextVault

@Suite("VaultManager — CRUD on disk")
struct VaultManagerTests {

    let tempDir: URL
    let vault: VaultManager

    init() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cv-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
        vault = VaultManager(root: dir)
    }

    // MARK: - Project lifecycle

    @Test func addProjectCreatesDirAndMetadata() throws {
        try vault.addProject(SeedData.project)

        let projectDir = tempDir.appendingPathComponent(SeedData.project.slug)
        #expect(FileManager.default.fileExists(atPath: projectDir.path))

        let metaURL = projectDir.appendingPathComponent(".project.json")
        #expect(FileManager.default.fileExists(atPath: metaURL.path))

        let data = try Data(contentsOf: metaURL)
        let decoded = try JSONDecoder().also { $0.dateDecodingStrategy = .iso8601 }
            .decode(Project.self, from: data)
        #expect(decoded.name == SeedData.project.name)
        #expect(decoded.rootPath == SeedData.project.rootPath)
    }

    @Test func addProjectAppearsInProjectsList() throws {
        try vault.addProject(SeedData.project)
        #expect(vault.projects.contains { $0.id == SeedData.project.id })
    }

    @Test func removeProjectDeletesDirAndUpdatesProjects() throws {
        try vault.addProject(SeedData.project)
        try vault.removeProject(SeedData.project)

        let projectDir = tempDir.appendingPathComponent(SeedData.project.slug)
        #expect(!FileManager.default.fileExists(atPath: projectDir.path))
        #expect(!vault.projects.contains { $0.id == SeedData.project.id })
    }

    @Test func projectForPathMatchesByPrefix() throws {
        try vault.addProject(SeedData.project)

        let found = vault.project(forPath: "/Users/dev/projects/my-app/Sources/main.swift")
        #expect(found?.id == SeedData.project.id)
    }

    @Test func projectForPathReturnNilOnMismatch() throws {
        try vault.addProject(SeedData.project)

        let notFound = vault.project(forPath: "/Users/dev/projects/other-app")
        #expect(notFound == nil)
    }

    @Test func projectsLoadedFromDiskOnInit() throws {
        try vault.addProject(SeedData.project)

        // New vault instance reading the same directory should see the project
        let vault2 = VaultManager(root: tempDir)
        #expect(vault2.projects.contains { $0.id == SeedData.project.id })
    }

    // MARK: - Note lifecycle

    @Test func writeNotePersistsMarkdownFile() throws {
        try vault.addProject(SeedData.project)
        try vault.writeNote(SeedData.contextNote, to: SeedData.project)

        let url = SeedData.project.notesDirectory(in: tempDir)
            .appendingPathComponent(SeedData.contextNote.filename)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content.contains("title: context"))
        #expect(content.contains("tags: [context]"))
        #expect(content.contains("GH-412"))
    }

    @Test func readNoteRoundTrip() throws {
        try vault.addProject(SeedData.project)
        try vault.writeNote(SeedData.architectureNote, to: SeedData.project)

        let read = vault.readNote(titled: "architecture", in: SeedData.project)
        #expect(read?.title == "architecture")
        #expect(read?.tags == ["architecture"])
        #expect(read?.body.contains("JWT HS256") == true)
    }

    @Test func notesListReturnsAllWrittenNotes() throws {
        try SeedData.seedVault(vault)

        let notes = vault.notes(for: SeedData.project)
        #expect(notes.count == 3)
        #expect(notes.map(\.title).sorted() == ["architecture", "context", "decisions"])
    }

    @Test func noteCountMatchesWrittenFiles() throws {
        try SeedData.seedVault(vault)

        #expect(vault.noteCount(for: SeedData.project) == 3)
    }

    @Test func deleteNoteRemovesFile() throws {
        try vault.addProject(SeedData.project)
        try vault.writeNote(SeedData.contextNote, to: SeedData.project)
        try vault.deleteNote(SeedData.contextNote, from: SeedData.project)

        let url = SeedData.project.notesDirectory(in: tempDir)
            .appendingPathComponent(SeedData.contextNote.filename)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(vault.notes(for: SeedData.project).isEmpty)
    }

    @Test func updateNoteOverwritesContent() throws {
        try vault.addProject(SeedData.project)
        try vault.writeNote(SeedData.contextNote, to: SeedData.project)

        var updated = SeedData.contextNote
        updated.body = "Updated body with new content."
        try vault.writeNote(updated, to: SeedData.project)

        let read = vault.readNote(titled: "context", in: SeedData.project)
        #expect(read?.body == "Updated body with new content.")
    }

    // MARK: - Search

    @Test func searchNotesFindsMatchInBody() throws {
        try SeedData.seedVault(vault)

        let results = vault.searchNotes(query: "JWT", in: SeedData.project)
        #expect(!results.isEmpty)
        #expect(results.contains { $0.title == "architecture" || $0.title == "decisions" })
    }

    @Test func searchNotesFindsMatchInTitle() throws {
        try SeedData.seedVault(vault)

        let results = vault.searchNotes(query: "context", in: SeedData.project)
        #expect(results.contains { $0.title == "context" })
    }

    @Test func searchNotesFindsMatchInTags() throws {
        try SeedData.seedVault(vault)

        let results = vault.searchNotes(query: "decisions", in: SeedData.project)
        #expect(results.contains { $0.title == "decisions" })
    }

    @Test func searchNotesEmptyQueryReturnsAll() throws {
        try SeedData.seedVault(vault)

        let results = vault.searchNotes(query: "", in: SeedData.project)
        #expect(results.count == 3)
    }

    @Test func searchNotesNoMatchReturnsEmpty() throws {
        try SeedData.seedVault(vault)

        let results = vault.searchNotes(query: "blockchain", in: SeedData.project)
        #expect(results.isEmpty)
    }
}

// Convenience to avoid verbose chaining
private extension JSONDecoder {
    func also(_ configure: (JSONDecoder) -> Void) -> JSONDecoder {
        configure(self); return self
    }
}
