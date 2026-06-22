import Foundation

enum MCPToolDefinitions {
    static let all: [[String: Any]] = [
        tool(
            "get_project_context",
            description: """
            ══ CALL THIS FIRST — before any other action, every session ══
            Returns: project slug, rootPath, note index, 'context.md' (recent state),
            and ▸map — a compact file→symbol map of the whole codebase.

            ── ▸map — use it to skip exploration ──
            Each line: "path/File.swift c:ClassName@12 f:method@40 s:Struct@88 …"
            Prefixes: c=class s=struct e=enum x=extension f=func · @N = start line.
            If you already know which file to edit (e.g. the task names it), find it in ▸map
            and go STRAIGHT to read_file with rootPath + "/" + the path — no search_code needed.
            Use search_code only when you DON'T know where the relevant code lives.

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
               Workflow: search_code → write code directly from chunk bodies → read_chunk only if a chunk was cut off
               ⚠️  Chunk bodies already contain class context. Do NOT call read_file to "verify" — trust the results.

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
            BM25 search over ALL indexed function/class/struct bodies. Returns full code inline.
            10–20× cheaper than read_file. Use this first — not grep, not directory listing.

            ── QUERY — KEEP IT SHORT: one or two words, or a single type/symbol name ──
            Short queries rank best. Long multi-term queries dilute the score and make you
            re-search. camelCase and snake_case are split automatically.
              ✓ "MCPToolDefinitions"    → the tool schema definitions, in one shot
              ✓ "websocket handshake"   → finds handleWsHandshake, WebSocketHandshakeManager…
              ✓ "struct CodeChunk"      → finds the CodeChunk struct definition
              ✗ "MCPToolDefinitions all inputSchema properties required" → too many terms, noisy
              ✗ "struct MCPToolDefinitions static let all entries schema" → re-searching, just say "MCPToolDefinitions"
            If a search returns the right file, STOP. Don't re-search it with more words.

            ── RESULT FORMAT ──
            Each match looks like:
              ▸ /absolute/path/to/file.swift:startLine-endLine [type name]
              // class ParentClass · relative/file.swift:line   ← class context header
              // var property; let other                         ← key parent properties
              <full function or type body>

            ── PATHS ARE ABSOLUTE ──
            The path after ▸ is the COMPLETE path, ready to use directly in read_file.
            Do NOT reconstruct it. Do NOT prepend anything. Copy it as-is.

            ── AFTER YOU GET RESULTS — write code immediately ──
            Each chunk body contains the full implementation with its class context.
            You have enough to write correct code after 1-3 searches.
            Do NOT call read_file "just to be sure" — trust the chunk bodies.
            If a chunk is cut off with [N lines — retrieve(hash:"…")] call retrieve() for the rest.

            ── WORKFLOW ──
              1. search_code("specific concept") → read chunk bodies inline
              2. search_code again with a different query if the first missed something
              3. Output your solution — stop searching after 3 calls

            Requires full index. If not indexed: ask user to click Re-index in ContextVault app.
            """,
            required: ["project", "query"],
            properties: [
                "project": ["type": "string", "description": "Project slug (from get_project_context)"],
                "query":   ["type": "string", "description": "Natural language keywords — camelCase/snake_case expanded automatically"],
                "topK":    ["type": "integer", "description": "Max results (default: 3, hard-capped at 5 — higher just adds noise)"]
            ]
        ),
        tool(
            "read_chunk",
            description: """
            Read a specific code chunk by file and start line (from a prior search_code result).
            Cheaper than reading the whole file. Use when you need a chunk you've already located.
            Pass the absolute path exactly as shown in the search_code ▸ header.
            """,
            required: ["project", "file", "line"],
            properties: [
                "project": ["type": "string", "description": "Project slug"],
                "file":    ["type": "string", "description": "Absolute file path from the ▸ header in search_code results"],
                "line":    ["type": "integer", "description": "Start line number from search_code result"]
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
