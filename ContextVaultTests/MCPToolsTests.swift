import Testing
import Foundation
@testable import ContextVault

// Integration tests for all 10 MCP tools using a real VaultManager backed by a temp directory.
// These tests verify the full request → VaultManager → disk → response pipeline.
@Suite("MCPTools — all 10 tools end-to-end")
struct MCPToolsTests {

    let tempDir: URL
    let vault: VaultManager
    let tools: MCPTools

    init() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cv-mcp-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
        vault = VaultManager(root: dir)
        tools = MCPTools(vault: vault)
        try SeedData.seedVault(vault)
    }

    // MARK: - get_project_context

    @Test func getProjectContextReturnsCompactSummary() {
        let result = tools.handle(
            name: "get_project_context",
            arguments: ["path": "/Users/dev/projects/my-app/Sources/main.swift"]
        )
        #expect(!result.isError)
        #expect(result.content.contains("my-app"))
        #expect(result.content.contains("▸ctx"))
        #expect(result.content.contains("▸idx"))
    }

    @Test func getProjectContextMissingPathReturnsError() {
        let result = tools.handle(name: "get_project_context", arguments: [:])
        #expect(result.isError)
    }

    @Test func getProjectContextUnknownPathReturnsHelpfulError() {
        let result = tools.handle(
            name: "get_project_context",
            arguments: ["path": "/totally/unknown/path"]
        )
        #expect(result.isError)
        #expect(result.content.contains("DO NOT create a project yourself"))
    }

    @Test func getProjectContextIsCacheable() {
        // Two calls with the same project and unmodified notes should return identical output.
        let args: [String: Any] = ["path": "/Users/dev/projects/my-app"]
        let r1 = tools.handle(name: "get_project_context", arguments: args)
        let r2 = tools.handle(name: "get_project_context", arguments: args)
        #expect(r1.content == r2.content)
    }

    // MARK: - list_notes

    @Test func listNotesReturnsAllThreeNotes() {
        let result = tools.handle(
            name: "list_notes",
            arguments: ["project": SeedData.project.slug]
        )
        #expect(!result.isError)
        #expect(result.content.contains("architecture"))
        #expect(result.content.contains("context"))
        #expect(result.content.contains("decisions"))
    }

    @Test func listNotesUnknownProjectReturnsError() {
        let result = tools.handle(name: "list_notes", arguments: ["project": "no-such-project"])
        #expect(result.isError)
    }

    // MARK: - read_note

    @Test func readNoteReturnsBodyAndMetadata() {
        let result = tools.handle(name: "read_note", arguments: [
            "project": SeedData.project.slug,
            "title": "architecture",
        ])
        #expect(!result.isError)
        #expect(result.content.contains("JWT HS256"))
        #expect(result.content.contains("▸architecture"))
    }

    @Test func readNoteMissingTitleReturnsError() {
        let result = tools.handle(name: "read_note", arguments: [
            "project": SeedData.project.slug,
        ])
        #expect(result.isError)
    }

    @Test func readNoteNotFoundListsAvailable() {
        let result = tools.handle(name: "read_note", arguments: [
            "project": SeedData.project.slug,
            "title": "does-not-exist",
        ])
        #expect(result.isError)
        #expect(result.content.contains("Available notes"))
    }

    // MARK: - write_note

    @Test func writeNoteCreatesNewNote() throws {
        let result = tools.handle(name: "write_note", arguments: [
            "project": SeedData.project.slug,
            "title": "testing",
            "body": "## Testing strategy\n\nAll critical paths covered.",
            "tags": ["tests"],
        ])
        #expect(!result.isError)
        #expect(result.content.contains("✓"))

        // Verify it's actually on disk
        let written = vault.readNote(titled: "testing", in: SeedData.project)
        #expect(written != nil)
        #expect(written?.body.contains("Testing strategy") == true)
        #expect(written?.tags == ["tests"])
    }

    @Test func writeNoteUpdatesExistingNote() throws {
        // Write it once
        tools.handle(name: "write_note", arguments: [
            "project": SeedData.project.slug,
            "title": "ephemeral",
            "body": "v1 content",
        ])
        // Update it
        tools.handle(name: "write_note", arguments: [
            "project": SeedData.project.slug,
            "title": "ephemeral",
            "body": "v2 updated content",
        ])

        let read = vault.readNote(titled: "ephemeral", in: SeedData.project)
        #expect(read?.body == "v2 updated content")
    }

    @Test func writeNotePreservesExistingTagsWhenNoneProvided() throws {
        // Seed note has tags: ["context"]
        tools.handle(name: "write_note", arguments: [
            "project": SeedData.project.slug,
            "title": "context",
            "body": "Updated content — no tags passed",
            // tags intentionally omitted
        ])

        let read = vault.readNote(titled: "context", in: SeedData.project)
        #expect(read?.tags == ["context"])
    }

    // MARK: - search_notes

    @Test func searchNotesFindsMatchAcrossBodyAndTitle() {
        let result = tools.handle(name: "search_notes", arguments: [
            "project": SeedData.project.slug,
            "query": "CoreData",
        ])
        #expect(!result.isError)
        #expect(result.content.contains("decisions"))
    }

    @Test func searchNotesNoMatchReturnsMessageNotError() {
        let result = tools.handle(name: "search_notes", arguments: [
            "project": SeedData.project.slug,
            "query": "blockchain",
        ])
        #expect(!result.isError)
        #expect(result.content.lowercased().contains("no notes"))
    }

    @Test func searchNotesMissingQueryReturnsError() {
        let result = tools.handle(name: "search_notes", arguments: [
            "project": SeedData.project.slug,
        ])
        #expect(result.isError)
    }

    // MARK: - retrieve (CCR)

    @Test func retrieveReturnsOffloadedContent() {
        let hash = CCRStore.shared.put("This is the offloaded content for testing CCR retrieval.")
        let result = tools.handle(name: "retrieve", arguments: ["hash": hash])
        #expect(!result.isError)
        #expect(result.content.contains("offloaded content"))
    }

    @Test func retrieveUnknownHashReturnsError() {
        let result = tools.handle(name: "retrieve", arguments: ["hash": "deadbeef000000"])
        #expect(result.isError)
        #expect(result.content.contains("not found"))
    }

    // MARK: - compress

    @Test func compressJSONReturnsColumnarTable() {
        let json = """
        [{"id":1,"name":"Alice","role":"admin"},{"id":2,"name":"Bob","role":"viewer"},{"id":3,"name":"Carol","role":"viewer"}]
        """
        let result = tools.handle(name: "compress", arguments: ["content": json])
        #expect(!result.isError)
        #expect(result.content.contains("[compress:json"))
        #expect(result.content.contains("cols:"))
    }

    @Test func compressReportsTokenReduction() {
        let bigJSON = String(data: (try? JSONSerialization.data(
            withJSONObject: (1...20).map { ["id": $0, "title": "Item \($0)", "status": "active"] }
        ))!, encoding: .utf8)!
        let result = tools.handle(name: "compress", arguments: ["content": bigJSON])
        // Header format: [compress:json ~XX%↓ orig→comp tokens saved≈N]
        #expect(result.content.contains("%↓"))
        #expect(result.content.contains("saved≈"))
    }

    @Test func compressMissingContentReturnsError() {
        let result = tools.handle(name: "compress", arguments: [:])
        #expect(result.isError)
    }

    @Test func compressWithTypeHintOverridesDetection() {
        let log = "Some text that looks like markdown but force-typed as log."
        let result = tools.handle(name: "compress", arguments: [
            "content": log,
            "type": "log",
        ])
        #expect(!result.isError)
        #expect(result.content.contains("[compress:log"))
    }

    // MARK: - Unknown tool

    @Test func unknownToolReturnsError() {
        let result = tools.handle(name: "do_magic", arguments: [:])
        #expect(result.isError)
        #expect(result.content.contains("Unknown tool"))
    }

    // MARK: - Output size guarantees

    @Test func getProjectContextOutputIsSmallerThanReadingAllNotes() throws {
        let ctxResult = tools.handle(
            name: "get_project_context",
            arguments: ["path": "/Users/dev/projects/my-app"]
        )
        #expect(!ctxResult.isError)

        // "Old way": read all note bodies concatenated
        let rawNotesSize = SeedData.allNotes.reduce(0) { $0 + $1.markdownFileContent().count }
        #expect(ctxResult.content.count < rawNotesSize,
            "get_project_context output (\(ctxResult.content.count) chars) should be smaller than raw notes (\(rawNotesSize) chars)")
    }
}
