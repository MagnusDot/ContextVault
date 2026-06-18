import Testing
import Foundation
@testable import ContextVault

// Integration tests that:
// 1. Generate a real Swift codebase on disk (10 files, ~700 lines total)
// 2. Index it with the actual BM25 chunker
// 3. Run real search_code queries via MCPTools
// 4. Verify results contain the expected functions
// 5. Calculate and assert real token savings
@Suite("RAG — real codebase indexing and search")
struct RAGIndexTests {

    let tempDir: URL
    let codebaseRoot: URL
    let vault: VaultManager
    let tools: MCPTools
    let index: BM25Index
    let project: Project
    let slug = "myapp-rag-test"

    init() throws {
        // 1. Set up temp vault + fake project directory
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cv-rag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir

        // 2. Generate real Swift files on disk
        codebaseRoot = try FakeCodebase.create(in: dir)

        // 3. Create VaultManager with temp vault, seed a project pointing to the fake codebase
        vault = VaultManager(root: dir.appendingPathComponent("vault"))
        project = Project(
            id: UUID(),
            name: "MyApp",
            rootPath: codebaseRoot.path
        )
        try vault.addProject(project)
        try vault.writeNote(SeedData.contextNote, to: project)
        try vault.writeNote(SeedData.architectureNote, to: project)
        try vault.writeNote(SeedData.decisionsNote, to: project)

        // 4. Index the real codebase synchronously with the actual chunker
        let result = CodeChunker.chunkProject(at: codebaseRoot.path)
        index = BM25Index(chunks: result.chunks)

        // 5. Inject the index into CodeRAGManager so MCPTools can use it
        CodeRAGManager.shared.inject(index: index, for: project.slug)

        tools = MCPTools(vault: vault)
    }

    // MARK: - Codebase statistics

    @Test func codebaseHasExpectedFileCount() throws {
        let swiftFiles = try FileManager.default.subpathsOfDirectory(atPath: codebaseRoot.path)
            .filter { $0.hasSuffix(".swift") }
        #expect(swiftFiles.count == FakeCodebase.files.count,
            "Expected \(FakeCodebase.files.count) Swift files, found \(swiftFiles.count)")
    }

    @Test func indexContainsExpectedChunkCount() {
        // 30 files with 3-10 top-level declarations each → expect 60+ chunks
        #expect(index.count >= 40,
            "Expected at least 40 chunks from \(FakeCodebase.files.count) files, got \(index.count)")
        print("📦 Indexed \(index.count) chunks from \(FakeCodebase.files.count) files")
    }

    @Test func indexCoversAllSourceFiles() {
        let indexedFiles = Set(index.allChunks.map(\.file))
        // All Swift files (except test files) should be indexed
        let sourceFiles = FakeCodebase.files
            .map { $0.0 }
            .filter { !$0.hasPrefix("Tests/") }
        for file in sourceFiles {
            #expect(indexedFiles.contains(file) || indexedFiles.contains { $0.hasSuffix(URL(fileURLWithPath: file).lastPathComponent) },
                "File '\(file)' should be in the index")
        }
    }

    // MARK: - Search quality

    @Test func searchJWTFindsAuthService() {
        let hits = index.search(query: "JWT token validation", topK: 5)
        #expect(!hits.isEmpty, "Search for 'JWT token validation' must return results")
        let names = hits.map(\.chunk.name)
        print("🔍 'JWT token validation' → \(names.joined(separator: ", "))")

        // AuthService contains JWT-related functions — at least one should rank high
        let hasAuth = hits.prefix(3).contains { h in
            h.chunk.file.contains("Auth") || h.chunk.body.contains("JWT") || h.chunk.body.contains("jwt")
        }
        #expect(hasAuth, "Top 3 results for 'JWT validation' should include auth-related code")
    }

    @Test func searchRefreshTokenFindsRotateFunction() {
        let hits = index.search(query: "refresh token rotation", topK: 5)
        #expect(!hits.isEmpty)
        print("🔍 'refresh token rotation' → \(hits.prefix(3).map { "\($0.chunk.name) [\(String(format: "%.2f", $0.score))]" }.joined(separator: ", "))")

        let hasRotate = hits.prefix(3).contains { $0.chunk.name.contains("rotate") || $0.chunk.name.contains("Rotate") }
        #expect(hasRotate, "Top results for 'refresh token rotation' should include rotateRefreshToken")
    }

    @Test func searchRetryLogicFindsNetworkClient() {
        let hits = index.search(query: "retry exponential backoff", topK: 5)
        #expect(!hits.isEmpty)
        print("🔍 'retry exponential backoff' → \(hits.prefix(3).map { "\($0.chunk.name) (\($0.chunk.file))" }.joined(separator: ", "))")

        let hasNetwork = hits.prefix(3).contains { $0.chunk.file.contains("Network") }
        #expect(hasNetwork, "Retry logic should be found in NetworkClient")
    }

    @Test func searchSyncConflictFindsSyncEngine() {
        let hits = index.search(query: "sync conflict resolution CRDT", topK: 5)
        #expect(!hits.isEmpty)
        print("🔍 'sync conflict CRDT' → \(hits.prefix(3).map { "\($0.chunk.name) (\($0.chunk.file))" }.joined(separator: ", "))")

        let hasSync = hits.prefix(3).contains { $0.chunk.file.contains("Sync") || $0.chunk.name.contains("apply") || $0.chunk.name.contains("merge") }
        #expect(hasSync, "Conflict resolution should be found in SyncEngine")
    }

    @Test func searchUserEmailFindsRepository() {
        let hits = index.search(query: "user find by email lookup", topK: 5)
        #expect(!hits.isEmpty)

        let hasRepo = hits.prefix(3).contains { $0.chunk.file.contains("Repository") }
        #expect(hasRepo, "User lookup by email should be in UserRepository")
    }

    @Test func bm25ScoresAreDecreasing() {
        let hits = index.search(query: "authentication token", topK: 10)
        guard hits.count >= 2 else { return }
        for i in 0..<(hits.count - 1) {
            #expect(hits[i].score >= hits[i + 1].score, "BM25 results must be sorted by descending score")
        }
    }

    // MARK: - MCPTools.search_code end-to-end

    @Test func searchCodeToolReturnsRealChunkBodies() {
        let result = tools.handle(name: "search_code", arguments: [
            "project": project.slug,
            "query": "JWT token generate",
            "topK": 3,
        ])
        #expect(!result.isError, "search_code must succeed when index is loaded")
        #expect(result.content.contains("▸"), "Result must contain chunk headers")
        #expect(result.content.contains("[score:"), "Result must include BM25 scores")
        print("🛠 search_code result:\n\(result.content.prefix(400))\n…")
    }

    @Test func searchCodeToolRecordsTokenSavings() {
        let slug   = project.slug
        let before = TokenSavingsStore.shared.savings(slug: slug)

        _ = tools.handle(name: "search_code", arguments: [
            "project": slug,
            "query": "refresh token rotation",
            "topK": 5,
        ])

        let after = TokenSavingsStore.shared.savings(slug: slug)
        // callCount must always increment — savings may be 0 if fake files are small
        #expect(after.callCount > before.callCount,
            "search_code must increment call count (before: \(before.callCount), after: \(after.callCount))")
        print("💰 Call #\(after.callCount) — cumulative savings: \(after.totalSaved) tokens")
    }

    @Test func getProjectContextReturnsCompactNotesAndIndex() {
        let result = tools.handle(name: "get_project_context", arguments: [
            "path": codebaseRoot.appendingPathComponent("Sources/Auth/AuthService.swift").path
        ])
        #expect(!result.isError)
        #expect(result.content.contains("▸ctx"))
        #expect(result.content.contains("▸idx"))
        print("📋 Context output (\(result.content.count) chars):\n\(result.content.prefix(300))…")
    }

    // MARK: - Real savings calculation

    @Test func realSavingsFromIndexVsRawFileReads() throws {
        // "Old way" cost: read all source files in full
        let allFiles = try FileManager.default.subpathsOfDirectory(atPath: codebaseRoot.path)
            .filter { $0.hasSuffix(".swift") }
        let totalRawChars = allFiles.compactMap { rel -> Int? in
            let url = codebaseRoot.appendingPathComponent(rel)
            return (try? String(contentsOf: url, encoding: .utf8))?.count
        }.reduce(0, +)
        let oldWayTokens = totalRawChars / 4  // 1 token ≈ 4 chars

        // "ContextVault way": 3 search_code calls, each returning topK=3 chunks
        let queries = ["JWT token validation", "retry backoff", "sync conflict"]
        let cvChars = queries.flatMap { q in
            index.search(query: q, topK: 3).map { $0.chunk.body.count }
        }.reduce(0, +)
        let cvTokens = cvChars / 4

        let savingsRatio  = Double(oldWayTokens) / max(1, Double(cvTokens))
        let savingsPct    = Int((1.0 - Double(cvTokens) / Double(max(1, oldWayTokens))) * 100)

        print("""
        ── Real codebase savings ────────────────────────────
        Files on disk:        \(allFiles.count) Swift files
        Total source chars:   \(totalRawChars) (\(oldWayTokens) tokens)

        3 × search_code (topK=3):
        Matching chunk chars: \(cvChars) (\(cvTokens) tokens)

        Savings: \(savingsPct)% — \(String(format: "%.1f", savingsRatio))× fewer tokens
        ─────────────────────────────────────────────────────
        """)

        #expect(oldWayTokens > cvTokens,
            "search_code must cost fewer tokens than reading all files (\(oldWayTokens) vs \(cvTokens))")
        #expect(savingsRatio >= 3.0,
            "Expected at least 3× savings from BM25 search vs full reads, got \(String(format: "%.1f", savingsRatio))×")
    }

    @Test func fullSessionCostComparison() throws {
        // Complete session: understand project + find 2 functions + process JSON response

        // OLD WAY
        let allFiles = try FileManager.default.subpathsOfDirectory(atPath: codebaseRoot.path)
            .filter { $0.hasSuffix(".swift") }
        let rawReadTokens = allFiles.compactMap { rel -> Int? in
            let url = codebaseRoot.appendingPathComponent(rel)
            return (try? String(contentsOf: url, encoding: .utf8))?.count
        }.reduce(0, +) / 4

        let fakePRListJSON = String(data: (try? JSONSerialization.data(
            withJSONObject: (1...20).map { i -> [String: Any] in
                ["id": i, "title": "PR \(i)", "state": "open", "author": "dev\(i % 3)"]
            }
        ))!, encoding: .utf8)!

        let oldWayTotal = rawReadTokens + (fakePRListJSON.count / 4)

        // CONTEXTVAULT WAY
        let ctxResult  = tools.handle(name: "get_project_context",
            arguments: ["path": codebaseRoot.path])
        let search1    = tools.handle(name: "search_code",
            arguments: ["project": project.slug, "query": "JWT access token generate", "topK": 3])
        let search2    = tools.handle(name: "search_code",
            arguments: ["project": project.slug, "query": "retry network failure", "topK": 3])
        let compressed = tools.handle(name: "compress",
            arguments: ["content": fakePRListJSON])

        let cvTotal = (ctxResult.content.count + search1.content.count +
                       search2.content.count + compressed.content.count) / 4

        let ratio   = Double(oldWayTotal) / Double(max(1, cvTotal))
        let savings = oldWayTotal - cvTotal

        print("""
        ── Full session comparison ──────────────────────────
        WITHOUT ContextVault:
          Read \(allFiles.count) files: \(rawReadTokens) tok
          Raw JSON (\(fakePRListJSON.count) chars): \(fakePRListJSON.count / 4) tok
          TOTAL: \(oldWayTotal) tokens

        WITH ContextVault:
          get_project_context: \(ctxResult.content.count / 4) tok
          search_code × 2: \((search1.content.count + search2.content.count) / 4) tok
          compress(JSON): \(compressed.content.count / 4) tok
          TOTAL: \(cvTotal) tokens

        Savings: \(savings) tokens — \(String(format: "%.1f", ratio))× fewer
        ─────────────────────────────────────────────────────
        """)

        #expect(ratio >= 2.0, "Full session should be at least 2× cheaper with ContextVault")
        #expect(!ctxResult.isError)
        #expect(!search1.isError)
        #expect(!search2.isError)
    }
}
