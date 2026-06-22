import Foundation

struct MCPToolResult {
    let content: String
    let isError: Bool

    static func ok(_ text: String) -> Self { .init(content: text, isError: false) }
    static func err(_ text: String) -> Self { .init(content: text, isError: true) }
}

final class MCPTools {
    private let vault: VaultManager

    init(vault: VaultManager) {
        self.vault = vault
    }

    func handle(name: String, arguments: [String: Any]) -> MCPToolResult {
        switch name {
        case "get_project_context": return getProjectContext(arguments)
        case "list_notes":          return listNotes(arguments)
        case "read_note":           return readNote(arguments)
        case "write_note":          return writeNote(arguments)
        case "search_notes":        return searchNotes(arguments)
        case "index_codebase":      return indexCodebase(arguments)
        case "retrieve":            return retrieveCCR(arguments)
        case "compress":            return compressContent(arguments)
        case "search_code":         return searchCode(arguments)
        case "read_chunk":          return readChunk(arguments)
        default:                    return .err("Unknown tool: \(name)")
        }
    }

    // MARK: - get_project_context

    private func getProjectContext(_ args: [String: Any]) -> MCPToolResult {
        guard let path = args["path"] as? String else {
            return .err("Missing required parameter: path")
        }

        guard let project = vault.project(forPath: path) else {
            let available = vault.projects.isEmpty
                ? "No projects registered yet."
                : vault.projects.map { "  • \($0.name) → \($0.rootPath)" }.joined(separator: "\n")
            return .err("""
            No ContextVault project found for: \(path)

            ⚠️  DO NOT create a project yourself.
            Ask the user to add this project in the ContextVault app:
            → Open ContextVault (Dock icon) → click '+' → enter name and path → confirm.
            Then restart your session.

            Registered projects:
            \(available)
            """)
        }

        let notes = vault.notes(for: project)

        // Fold the code index identity into the cache hash so a re-index busts the cache
        // even when notes are unchanged.
        let rag = CodeRAGManager.shared
        let indexFingerprint = rag.bm25(slug: project.slug).map { "\($0.count)" } ?? "0"
        let contentHash = CacheAligner.shared.hash(for: notes) + ":" + indexFingerprint
        let cacheKey = "ctx:\(project.slug)"
        if let cached = CacheAligner.shared.get(key: cacheKey, contentHash: contentHash) {
            return .ok(cached)
        }

        let fmt = compactDateFmt

        var byTag: [String: [Note]] = [:]
        var untagged: [Note] = []
        for note in notes {
            if let first = note.tags.first { byTag[first, default: []].append(note) }
            else { untagged.append(note) }
        }
        var idxLines: [String] = []
        for (tag, tagNotes) in byTag.sorted(by: { $0.key < $1.key }) {
            let items = tagNotes.map { "\($0.title)·\(fmt.string(from: $0.updatedAt))" }.joined(separator: " ")
            idxLines.append("[\(tag)] \(items)")
        }
        if !untagged.isEmpty {
            idxLines.append("[·] " + untagged.map(\.title).joined(separator: " "))
        }

        let ctxBody: String
        if let ctx = vault.readNote(titled: "context", in: project) ?? vault.readNote(titled: "Context", in: project) {
            ctxBody = ctx.body.isEmpty ? "(empty)" : ResponseCompressor.compressNote(ctx.body, title: "context")
        } else {
            ctxBody = "∅ — write_note(project:\"\(project.slug)\",title:\"context\",body:\"...\",tags:[\"context\"])"
        }

        let mapSection = buildCodeMap(slug: project.slug)

        let output = """
        ⬡ \(project.slug) \(project.rootPath) \(notes.count)♦
        ▸ctx
        \(ctxBody)
        ▸idx
        \(idxLines.isEmpty ? "∅" : idxLines.joined(separator: "\n"))
        \(mapSection)▸how use ▸map to jump straight to the file you need · search_code only when location is unknown · act as soon as you have enough, don't repeat a search or re-read what you already have
        ▸ read/write notes freely — no limit
        """

        CacheAligner.shared.set(key: cacheKey, contentHash: contentHash, output: output)
        return .ok(output)
    }

    // Compact file→symbol map built from the in-memory BM25 index (no disk re-scan).
    // Lets the agent jump straight to the right file with ONE call — no search_code round-trips
    // for tasks where the location is obvious. Format mirrors index_codebase (agents know it).
    private func buildCodeMap(slug: String) -> String {
        guard let index = CodeRAGManager.shared.bm25(slug: slug), index.count > 0 else { return "" }

        let prefix: [CodeChunk.ChunkType: String] = [
            .class_: "c", .struct_: "s", .enum_: "e", .extension_: "x", .function: "f"
        ]

        var byFile: [String: [CodeChunk]] = [:]
        for chunk in index.allChunks { byFile[chunk.file, default: []].append(chunk) }

        // Order files by centrality (aider-style): a file whose symbols are referenced from all
        // over the codebase is the structural core an agent should see first — far more useful
        // for a cold start than just "the file with the most declarations".
        func weight(_ chunks: [CodeChunk]) -> Int {
            chunks.reduce(0) { $0 + index.referenceCount($1.name) }
        }
        let ordered = byFile.sorted {
            let w0 = weight($0.value), w1 = weight($1.value)
            return w0 != w1 ? w0 > w1 : $0.value.count > $1.value.count
        }

        var lines: [String] = []
        for (file, chunks) in ordered {
            let syms = chunks
                .sorted { $0.startLine < $1.startLine }
                .prefix(12)
                .map { "\(prefix[$0.type] ?? "?"):\($0.name)@\($0.startLine)" }
                .joined(separator: " ")
            let more = chunks.count > 12 ? " +\(chunks.count - 12)" : ""
            lines.append("\(file) \(syms)\(more)")
        }

        // Cap inline; offload the long tail to CCR so huge projects don't blow context.
        let inlineMax = 50
        let header = "▸map (\(byFile.count) files · most-referenced first · c=class s=struct e=enum x=ext f=func)\n"
        if lines.count > inlineMax {
            let inline = lines.prefix(inlineMax).joined(separator: "\n")
            let tail = lines.dropFirst(inlineMax).joined(separator: "\n")
            let hash = CCRStore.shared.put(tail)
            return header + inline + "\n[\(lines.count - inlineMax) more files — retrieve(hash:\"\(hash)\")]\n"
        }
        return header + lines.joined(separator: "\n") + "\n"
    }

    // MARK: - list_notes

    private func listNotes(_ args: [String: Any]) -> MCPToolResult {
        guard let slug = args["project"] as? String,
              let project = vault.projects.first(where: { $0.slug.lowercased() == slug.lowercased() })
        else { return .err(noProject(args["project"] as? String)) }

        let notes = vault.notes(for: project)
        guard !notes.isEmpty else { return .ok("∅") }

        let fmt = compactDateFmt
        let list = notes.map { n -> String in
            let tags = n.tags.isEmpty ? "" : " [\(n.tags.joined(separator: ","))]"
            return "\(n.title)\(tags) \(fmt.string(from: n.updatedAt))"
        }.joined(separator: "\n")

        return .ok(list)
    }

    // MARK: - read_note

    private func readNote(_ args: [String: Any]) -> MCPToolResult {
        guard let slug = args["project"] as? String,
              let title = args["title"] as? String,
              let project = vault.projects.first(where: { $0.slug.lowercased() == slug.lowercased() })
        else { return .err("Missing required: project, title") }

        guard let note = vault.readNote(titled: title, in: project) else {
            let available = vault.notes(for: project).map { "  • \($0.title)" }.joined(separator: "\n")
            return .err("Note '\(title)' not found in '\(slug)'.\n\nAvailable notes:\n\(available)")
        }

        let compressed = ResponseCompressor.compressNote(note.body, title: note.title)
        let meta = "▸\(note.title) [\(note.tags.joined(separator: ","))] \(compactDateFmt.string(from: note.updatedAt))\n"
        return .ok(meta + compressed)
    }

    // MARK: - write_note

    private func writeNote(_ args: [String: Any]) -> MCPToolResult {
        guard let slug = args["project"] as? String,
              let title = args["title"] as? String,
              let body = args["body"] as? String,
              let project = vault.projects.first(where: { $0.slug.lowercased() == slug.lowercased() })
        else { return .err("Missing required: project, title, body") }

        let tags = args["tags"] as? [String] ?? []
        let existing = vault.readNote(titled: title, in: project)
        let note = Note(
            id: existing?.id ?? UUID(),
            title: title,
            body: body,
            tags: tags.isEmpty ? (existing?.tags ?? []) : tags,
            lastClaudeModifiedAt: Date(),
            projectSlug: slug
        )

        do {
            try vault.writeNote(note, to: project)
            return .ok("✓ '\(title)' saved in \(project.name).")
        } catch {
            return .err("Write failed: \(error.localizedDescription)")
        }
    }

    // MARK: - search_notes

    private func searchNotes(_ args: [String: Any]) -> MCPToolResult {
        guard let slug = args["project"] as? String,
              let query = args["query"] as? String,
              let project = vault.projects.first(where: { $0.slug.lowercased() == slug.lowercased() })
        else { return .err("Missing required: project, query") }

        let results = vault.searchNotes(query: query, in: project)
        guard !results.isEmpty else {
            return .ok("No notes matching '\(query)' in \(project.name).")
        }

        let hits = results.map { n -> String in
            let preview = n.body.prefix(100).replacingOccurrences(of: "\n", with: " ")
            let tags = n.tags.isEmpty ? "" : " [\(n.tags.joined(separator: ","))]"
            return "▸\(n.title)\(tags)\n\(preview)…"
        }.joined(separator: "\n")

        return .ok("\(results.count)♦ \"\(query)\"\n\(hits)")
    }

    // MARK: - retrieve (CCR)

    private func retrieveCCR(_ args: [String: Any]) -> MCPToolResult {
        guard let hash = args["hash"] as? String else {
            return .err("Missing required: hash")
        }
        guard let content = CCRStore.shared.get(hash) else {
            return .err("CCR hash '\(hash)' not found or expired. Re-read the note with read_note.")
        }
        return .ok(content)
    }

    // MARK: - index_codebase

    private func indexCodebase(_ args: [String: Any]) -> MCPToolResult {
        guard let slug = args["project"] as? String,
              let project = vault.projects.first(where: { $0.slug.lowercased() == slug.lowercased() })
        else { return .err(noProject(args["project"] as? String)) }

        let exts = args["extensions"] as? [String]
        let maxDepth = args["maxDepth"] as? Int ?? 8
        let scanPath = (args["path"] as? String) ?? project.rootPath

        let indexes = CodeIndexer.index(at: scanPath, extensions: exts, maxDepth: maxDepth)
        let raw = CodeIndexer.format(indexes, rootPath: scanPath)

        let hash = CacheAligner.shared.hash(for: raw)
        let cacheKey = "idx:\(project.slug):\(scanPath)"
        if let cached = CacheAligner.shared.get(key: cacheKey, contentHash: hash) {
            return .ok(cached)
        }

        let lines = raw.components(separatedBy: "\n")
        let output: String
        if lines.count > 120 {
            let inline = lines.prefix(80).joined(separator: "\n")
            let tail = lines.dropFirst(80).joined(separator: "\n")
            let tailHash = CCRStore.shared.put(tail)
            output = inline + "\n[\(lines.count - 80) more files — retrieve(hash:\"\(tailHash)\")]"
        } else {
            output = raw
        }

        CacheAligner.shared.set(key: cacheKey, contentHash: hash, output: output)
        return .ok(output)
    }

    // MARK: - compress (universal proxy compressor)
    // Headroom "proxy pattern": Claude passes any tool output here for compression.

    private func compressContent(_ args: [String: Any]) -> MCPToolResult {
        guard let content = args["content"] as? String, !content.isEmpty else {
            return .err("Missing required: content")
        }
        let typeHint = args["type"] as? String

        let origLen = content.count
        let origTokens = origLen / 4

        let type_: ResponseCompressor.ContentType
        if let hint = typeHint {
            switch hint {
            case "json":     type_ = .json
            case "log":      type_ = .log
            case "markdown": type_ = .markdown
            case "code":     type_ = .code
            default:         type_ = ResponseCompressor.detect(content)
            }
        } else {
            type_ = ResponseCompressor.detect(content)
        }

        let compressed: String
        switch type_ {
        case .json:     compressed = ResponseCompressor.compressJSON(content)
        case .log:      compressed = ResponseCompressor.compressLog(content)
        case .markdown: compressed = ResponseCompressor.compressMarkdown(content)
        case .code:     compressed = content
        }

        let compLen = compressed.count
        let compTokens = compLen / 4
        let saved = origTokens - compTokens
        let pct = origTokens > 0 ? Int((1.0 - Double(compTokens) / Double(origTokens)) * 100) : 0

        let header = "[compress:\(type_) ~\(pct)%↓ \(origTokens)→\(compTokens) tokens saved≈\(saved)]"
        return .ok("\(header)\n\(compressed)")
    }

    // MARK: - search_code (RAG)

    private func searchCode(_ args: [String: Any]) -> MCPToolResult {
        guard let rawProject = args["project"] as? String,
              let query = args["query"] as? String
        else { return .err("Missing required: project, query") }

        // Accept a project slug OR any absolute path inside the project.
        let project = vault.projects.first(where: { $0.slug.lowercased() == rawProject.lowercased() })
            ?? vault.project(forPath: rawProject)
        guard let project else { return .err(noProject(rawProject)) }

        let rag = CodeRAGManager.shared
        let slug = project.slug
        guard rag.isIndexed(slug: slug) else {
            return .err("""
            Project '\(project.slug)' has no code index yet.
            Ask the user to click "Re-index" in the Code Index panel (toolbar button ⚡), or call index_codebase first.
            """)
        }

        // Hard cap: large topK floods context with weak matches and triggers fishing loops.
        let topK = min(args["topK"] as? Int ?? 3, 5)
        let raw = rag.search(slug: slug, query: query, topK: max(topK, 5))
        guard let top = raw.first else {
            return .ok("∅ no match for '\(query)' — this concept likely doesn't exist in the codebase yet. If you're adding a NEW feature, proceed and write it without searching further.")
        }

        // Relative cutoff: drop the long tail of weak matches (< 45% of best score).
        // A noise query (concept not in code) collapses to 1-2 results instead of a 10-chunk dump.
        let floor = top.score * 0.45
        let results = Array(raw.filter { $0.score >= floor }.prefix(topK))

        // Weak-top detection — the grep-empty equivalent for BM25.
        // If the best match covers less than half the query's meaningful tokens,
        // it's a thematic miss: tell the agent to stop searching and build.
        let qTokens = Set(BM25Index.tokenize(query))
        let topTokens = Set(BM25Index.tokenize(top.chunk.body))
        let coverage = qTokens.isEmpty ? 1.0 : Double(qTokens.intersection(topTokens).count) / Double(qTokens.count)
        let weakHint = coverage < 0.5
            ? "⚠ weak matches (\(Int(coverage * 100))% term coverage) — this may be a NEW feature not yet in the code. Don't keep searching; write it from the patterns below.\n\n"
            : ""

        let fmt = results.map { r -> String in
            let c = r.chunk
            // Header: absolute path — use directly with read_file, no construction needed
            let absPath = "\(project.rootPath)/\(c.file)"
            let header = "▸ \(absPath):\(c.startLine)-\(c.endLine) [\(c.type.rawValue) \(c.name)]"
            // Body: cap at 50 lines to keep context lean
            let lines = c.body.components(separatedBy: "\n")
            let body: String
            if lines.count > 50 {
                let inline = lines.prefix(40).joined(separator: "\n")
                let rest = lines.dropFirst(40).joined(separator: "\n")
                let hash = CCRStore.shared.put(rest)
                body = inline + "\n... [\(lines.count - 40) lines — retrieve(hash:\"\(hash)\")]"
            } else {
                body = c.body
            }
            return "\(header)\n\(body)"
        }.joined(separator: "\n\n---\n\n")

        // Cost of reading each unique file in full vs what we actually returned.
        // avgFileTokens: based on real chunk data from the index (chars/4, adjusted for file coverage).
        let searchTokens = results.reduce(0) { $0 + $1.chunk.body.count / 4 }
        let uniqueFiles  = Set(results.map(\.chunk.file)).count
        let avgFileTokens: Int
        if let index = rag.bm25(slug: slug) {
            let fileCount = max(1, Set(index.allChunks.map(\.file)).count)
            avgFileTokens = index.allChunks.reduce(0) { $0 + $1.body.count } / fileCount / 4
        } else {
            avgFileTokens = 1500  // fallback: typical source file estimate
        }
        let readTokens = uniqueFiles * avgFileTokens
        TokenSavingsStore.shared.record(slug: slug, savedTokens: readTokens - searchTokens)

        return .ok("\(weakHint)\(results.count) match\(results.count == 1 ? "" : "es") for '\(query)':\n\n\(fmt)")
    }

    // MARK: - read_chunk

    private func readChunk(_ args: [String: Any]) -> MCPToolResult {
        guard let slug = args["project"] as? String,
              let rawFile = args["file"] as? String,
              let line = args["line"] as? Int
        else { return .err("Missing required: project, file, line") }

        // Accept both absolute paths (from search_code ▸ headers) and relative paths
        let file: String
        if let project = vault.projects.first(where: { $0.slug.lowercased() == slug.lowercased() }),
           rawFile.hasPrefix(project.rootPath) {
            file = String(rawFile.dropFirst(project.rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            file = rawFile
        }

        let rag = CodeRAGManager.shared
        guard let chunk = rag.chunk(slug: slug, file: file, startLine: line) else {
            return .err("No chunk found at \(file):\(line) in '\(slug)'. Use search_code to find the right file and line.")
        }

        let header = "▸ \(chunk.file):\(chunk.startLine)–\(chunk.endLine) · \(chunk.type.rawValue) \(chunk.name)"
        return .ok("\(header)\n\(chunk.body)")
    }

    // MARK: - Helpers

    private var compactDateFmt: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        return f
    }

    private func noProject(_ slug: String?) -> String {
        let list = vault.projects.isEmpty
            ? "No projects registered yet."
            : vault.projects.map { "  • \($0.slug) (\($0.name))" }.joined(separator: "\n")
        let req = slug.map { "'\($0)'" } ?? "(nil)"
        return """
        Project \(req) not found.

        ⚠️  DO NOT create a project yourself.
        Ask the user to create it in the ContextVault app.

        Available projects:
        \(list)
        """
    }
}
