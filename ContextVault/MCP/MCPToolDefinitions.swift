import Foundation

enum MCPToolDefinitions {
    static let all: [[String: Any]] = [
        tool(
            "get_project_context",
            description: """
            Call first, once per session. Returns the project's notes (context/decisions/architecture), \
            ▸map (compact file→symbol map of the whole codebase), and ▸how (a short working guide). \
            Use ▸map to choose files without directory scans. Then use search_code for patch-ready chunks \
            and same-file anchors. If no project matches the path, ask the user to add it in the app.
            """,
            required: ["path"],
            properties: [
                "path": ["type": "string", "description": "Current working directory ($PWD)"]
            ]
        ),
        tool(
            "list_notes",
            description: "List the project's notes (title, tags, updated date).",
            required: ["project"],
            properties: [
                "project": ["type": "string", "description": "Project slug (from get_project_context)"]
            ]
        ),
        tool(
            "read_note",
            description: "Read a note's full content by exact title.",
            required: ["project", "title"],
            properties: [
                "project": ["type": "string", "description": "Project slug"],
                "title":   ["type": "string", "description": "Exact note title"]
            ]
        ),
        tool(
            "write_note",
            description: """
            Create or update a project note — persistent memory across sessions. Record architecture \
            decisions, bug root causes, non-obvious constraints, and next steps; not things already in \
            the code or git. Update the 'context' note at the end of a session. Server adds frontmatter; \
            use [[wikilinks]] to cross-reference.
            """,
            required: ["project", "title", "body"],
            properties: [
                "project": ["type": "string", "description": "Project slug"],
                "title":   ["type": "string", "description": "Note title (becomes filename)"],
                "body":    ["type": "string", "description": "Markdown content (no frontmatter — server handles it)"],
                "tags":    ["type": "array", "items": ["type": "string"], "description": "Semantic tags, e.g. architecture, decisions, bugs, context"]
            ]
        ),
        tool(
            "search_notes",
            description: "Full-text search over note titles, bodies, and tags. Returns title + preview per match.",
            required: ["project", "query"],
            properties: [
                "project": ["type": "string", "description": "Project slug"],
                "query":   ["type": "string", "description": "Keywords (title + body + tags)"]
            ]
        ),
        tool(
            "retrieve",
            description: "Fetch offloaded lines by hash. Call only when a prior result says required code was omitted.",
            required: ["hash"],
            properties: [
                "hash": ["type": "string", "description": "Hash from the <<ccr:HASH>> marker"]
            ]
        ),
        tool(
            "index_codebase",
            description: """
            Scan sources and return a compact symbol map (names + locations only). Use only when there's \
            no full code index yet — otherwise prefer search_code, which returns real bodies ranked by relevance.
            """,
            required: ["project"],
            properties: [
                "project":    ["type": "string", "description": "Project slug"],
                "path":       ["type": "string", "description": "Subdirectory to scan (default: project root)"],
                "extensions": ["type": "array", "items": ["type": "string"], "description": "Filter by extensions, e.g. [\"swift\"]"],
                "maxDepth":   ["type": "integer", "description": "Max directory depth (default: 8)"]
            ]
        ),
        tool(
            "search_code",
            description: """
            BM25 search over indexed code. Use SHORT queries (one or two words, or one symbol); long queries \
            add noise. Returns patch-ready function/type chunks plus same-file symbol anchors for insertion. \
            Do not read_file just to verify a hit; use read_chunk/retrieve only when required code is omitted.
            """,
            required: ["project", "query"],
            properties: [
                "project": ["type": "string", "description": "Project slug (from get_project_context)"],
                "query":   ["type": "string", "description": "1–2 keywords or a symbol name — camelCase/snake_case split automatically"],
                "topK":    ["type": "integer", "description": "Max results (default 2, capped at 3)"]
            ]
        ),
        tool(
            "read_chunk",
            description: "Re-read one code chunk by file + start line (from a search_code ▸ header). Pass the absolute path as shown.",
            required: ["project", "file", "line"],
            properties: [
                "project": ["type": "string", "description": "Project slug"],
                "file":    ["type": "string", "description": "Absolute path from a search_code ▸ header"],
                "line":    ["type": "integer", "description": "Start line from the result"]
            ]
        ),
        tool(
            "compress",
            description: """
            Compress any large tool output (JSON, logs, markdown) before reading it — 40–70% savings, type \
            auto-detected. Returns a [compress:…] header; offloaded parts appear as <<ccr:HASH>>, fetch with \
            retrieve only if needed.
            """,
            required: ["content"],
            properties: [
                "content": ["type": "string", "description": "Raw content to compress"],
                "type":    ["type": "string", "description": "Optional hint: json | log | markdown (auto-detected if omitted)"]
            ]
        )
    ]

    private static func tool(_ name: String, description: String, required: [String], properties: [String: Any]) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": required
            ]
        ]
    }
}
