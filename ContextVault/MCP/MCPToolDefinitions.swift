import Foundation

enum MCPToolDefinitions {
    static let all: [[String: Any]] = [
        tool(
            "get_project_context",
            description: """
            ══ CALL THIS FIRST — before any other action, every session ══
            Returns: project slug, rootPath, note index, and 'context.md' (recent decisions + state).

            ── If no project found for your path ──
            DO NOT create a project yourself. Tell the user:
            "No ContextVault project found for this directory. Please add it in the ClaudeVault \
            app (Dock icon → '+' button), then restart the session."
            Then stop and wait.

            ── TOKEN BUDGET — read this once, apply always ──

            1. CODE SEARCH (when indexedAt is set in the response)
               search_code("natural words")  →  BM25 over ALL indexed functions/classes/structs
               Costs ~80–200 tokens. Alternative (grep + Read file) costs ~1 500 tokens. 10–20× cheaper.
               Rule: NEVER use Bash grep + Read to explore code when the index exists.
               Workflow: search_code → read_chunk (if more context needed) → Bash Read (last resort only)

            2. CODE SEARCH (when indexedAt is null)
               Use index_codebase for a symbol map (names + locations).
               Ask the user to run a full index: ContextVault app → project home → "Index now".

            3. COMPRESS LARGE TOOL OUTPUTS
               When any MCP tool (GitHub, Slack, Linear, Bash…) returns > 200 lines:
               Pass the output through compress(content: "…") before reading it.
               Savings: 40–70% on JSON arrays, logs, markdown. Detects type automatically.

            4. CCR MARKERS — content offloaded to save context
               When a response contains  <<ccr:HASH N_lines>>
               → the N lines were offloaded. Call retrieve(hash: "HASH") ONLY if you need them.
               Most of the time you don't — skip and move on.

            5. CACHE — KV cache efficiency
               This tool's output is cached for 270 s (Anthropic KV cache window).
               Call it with identical args each session to guarantee a cache hit.
               Re-call only after a major state change (new notes, re-index).

            ── END OF SESSION ──
            Always write_note(title:"context", body:"…") to persist the session state.
            Include: what changed, decisions made, blockers, next steps.
            """,
            required: ["path"],
            properties: [
                "path": ["type": "string", "description": "Your current working directory ($PWD)"]
            ]
        ),
        tool(
            "list_notes",
            description: "List all notes in the project with title, tags, and last updated date.",
            required: ["project"],
            properties: [
                "project": ["type": "string", "description": "Project slug (from get_project_context)"]
            ]
        ),
        tool(
            "read_note",
            description: "Read the full content of a specific note.",
            required: ["project", "title"],
            properties: [
                "project": ["type": "string", "description": "Project slug"],
                "title":   ["type": "string", "description": "Exact note title"]
            ]
        ),
        tool(
            "write_note",
            description: """
            Create or update a note. Use this to persist valuable context between sessions.

            WHEN to write:
            - Architecture decisions made during this session
            - Bugs found and their root causes
            - Non-obvious constraints or invariants discovered
            - TODO items or next steps
            - End-of-session state summary → write to 'context.md'

            WHEN NOT to write:
            - Information already in the codebase (git log, comments, README)
            - Temporary debugging notes
            - Do NOT create a project note (e.g. '.project.json') — only the user creates projects

            Frontmatter format (always include):
            ---
            title: Note Title
            tags: [architecture, decisions, bugs]   ← pick relevant tags
            status: seed | developing | mature      ← how complete is this note
            updatedAt: <auto-set by server>
            ---

            Keep notes between 50–300 lines. Split if covering multiple distinct concepts.
            Use [[Other Note]] wikilink syntax to cross-reference notes.
            Update 'context.md' at the end of any significant session to summarize recent state.
            """,
            required: ["project", "title", "body"],
            properties: [
                "project": ["type": "string", "description": "Project slug"],
                "title":   ["type": "string", "description": "Note title (becomes filename)"],
                "body":    ["type": "string", "description": "Full Markdown content (without frontmatter — server handles it)"],
                "tags":    ["type": "array", "items": ["type": "string"], "description": "Semantic tags: architecture, decisions, bugs, context, api, database, etc."]
            ]
        ),
        tool(
            "search_notes",
            description: "Full-text search across all note titles, bodies, and tags. Returns title + 100-char preview per match.",
            required: ["project", "query"],
            properties: [
                "project": ["type": "string", "description": "Project slug"],
                "query":   ["type": "string", "description": "Keywords to search (searches title + body + tags)"]
            ]
        ),
        tool(
            "retrieve",
            description: """
            Retrieve full content that was offloaded by the compression layer (CCR).
            When a response contains <<ccr:HASH N_lines_offloaded>>, call retrieve(hash: "HASH")
            to get the complete original. Only call this if you actually need the offloaded content.
            """,
            required: ["hash"],
            properties: [
                "hash": ["type": "string", "description": "12-char hash from the <<ccr:HASH>> marker"]
            ]
        ),
        tool(
            "index_codebase",
            description: """
            Scan source files and return a compact symbol index (names + locations only).
            Output format: one line per file → "path/file.ext: T:Name@line ..."
            Type prefixes: F=func C=class S=struct E=enum P=protocol I=interface T=type X=extension M=method

            Use this ONLY when:
            - The project has no full code index (indexedAt null in get_project_context)
            - You need a bird's-eye map of what exists and where
            - You want exact file locations before a targeted Read

            PREFER search_code over this when the full index exists — search_code returns
            the actual function bodies, not just names, and ranks by relevance.

            Call once per session. Re-call only after major refactors.
            Supported: swift ts tsx js jsx py go rs kt
            """,
            required: ["project"],
            properties: [
                "project":    ["type": "string", "description": "Project slug"],
                "path":       ["type": "string", "description": "Subdirectory to scan (default: project root)"],
                "extensions": ["type": "array", "items": ["type": "string"], "description": "Filter by extensions e.g. [\"swift\"] (default: all supported)"],
                "maxDepth":   ["type": "integer", "description": "Max directory depth (default: 8)"]
            ]
        ),
        tool(
            "search_code",
            description: """
            BM25 semantic search over ALL indexed function/class/struct bodies.
            Returns matching chunks with full code inline — no file reads needed.

            ALWAYS USE THIS instead of Bash grep + Read file when the index exists.
            Token cost: search_code ≈ 80 tokens vs grep + Read ≈ 800 tokens (10× cheaper).

            TOKENIZER — camelCase and snake_case are expanded automatically:
              "fetchUserProfile"  → searches: fetch · user · profile · fetchuserprofile
              "websocket_handshake" → searches: websocket · handshake
            So query with natural words, not exact symbol names:
              ✓ search_code("websocket handshake")   ← finds fetchWebSocketHandshake, handleWsHandshake…
              ✓ search_code("json compress array")   ← finds SmartCrusher.crush, compressJSON…
              ✓ search_code("auth token expire")     ← finds checkTokenExpiry, invalidateSession…
              ✗ search_code("fetchWebSocketHandshake") ← too specific, may miss synonyms

            RANKING — results sorted by BM25 relevance score.
            Score > 3.0 → strong match. Score < 1.0 → weak, likely noise.
            The index covers the full codebase (not just top N chunks).

            RESULT FORMAT per chunk:
              file: path/to/file.swift
              lines: 42–98  (startLine–endLine)
              type: function | class | struct | enum | extension
              name: FunctionOrTypeName
              score: 4.23
              body: <full source code>
            Chunks > 80 lines are CCR-offloaded — call retrieve(hash) only if needed.

            WORKFLOW:
              1. search_code("concept") → scan results, read bodies inline
              2. If you need more context around a chunk: read_chunk(project, file, line)
              3. Only use Bash Read as a last resort (no index, or need surrounding context)

            Requires full index (indexedAt set in get_project_context).
            """,
            required: ["project", "query"],
            properties: [
                "project": ["type": "string", "description": "Project slug (from get_project_context)"],
                "query":   ["type": "string", "description": "Natural language keywords — camelCase expanded, snake_case split, stop-words removed"],
                "topK":    ["type": "integer", "description": "Max results (default: 5, max recommended: 20)"]
            ]
        ),
        tool(
            "read_chunk",
            description: """
            Read a specific code chunk by file path and start line.
            Use after search_code to re-read a chunk you already identified.
            Much cheaper than reading the whole file with a Read tool.
            """,
            required: ["project", "file", "line"],
            properties: [
                "project": ["type": "string", "description": "Project slug"],
                "file":    ["type": "string", "description": "File path relative to project root (from search_code result)"],
                "line":    ["type": "integer", "description": "Start line number (from search_code result)"]
            ]
        ),
        tool(
            "compress",
            description: """
            Universal content compressor (headroom proxy pattern).
            Pass ANY large tool output here to compress it before processing.

            USE THIS WHEN you receive large outputs from other tools:
            - JSON arrays from GitHub/Linear/Slack MCPs → SmartCrusher table format (40–70% savings)
            - Bash command outputs (logs, build output) → log compressor (keeps errors, drops INFO/DEBUG)
            - Large markdown documents → normalize + CCR offload
            - Any content over ~200 lines

            The response includes:
            - A header: [compress:type ~X%↓ N→M tokens]
            - The compressed content (inline portion)
            - A <<ccr:HASH>> marker if content was offloaded — call retrieve(hash:) only if needed

            Automatically detects content type. Pass type hint to override: "json", "log", "markdown".
            """,
            required: ["content"],
            properties: [
                "content": ["type": "string", "description": "Raw content to compress (from any tool output)"],
                "type":    ["type": "string", "description": "Optional type hint: json | log | markdown (auto-detected if omitted)"]
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
