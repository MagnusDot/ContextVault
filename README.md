<div align="center">
  <img src="icon.png" width="96" alt="ClaudeVault icon"/>
  <h1>ClaudeVault</h1>
  <p><strong>Persistent memory + token optimization layer for Claude Code</strong></p>
  <p>
    <img src="https://img.shields.io/badge/platform-macOS%2026.4%2B-blue?style=flat-square&logo=apple"/>
    <img src="https://img.shields.io/badge/swift-6.0-orange?style=flat-square&logo=swift"/>
    <img src="https://img.shields.io/badge/MCP-WebSocket%20%3A9876-purple?style=flat-square"/>
    <img src="https://img.shields.io/badge/token%20savings-up%20to%2098%25-brightgreen?style=flat-square"/>
    <img src="https://img.shields.io/badge/dependencies-zero-lightgrey?style=flat-square"/>
  </p>
</div>

---

## The problem

Every Claude Code session starts **completely blind**.

Claude has no memory of what you worked on yesterday, what decisions were made, what the architecture looks like, or where the relevant functions live. It has to rediscover all of this — by reading files.

Every session:
- Reads 5–20 source files to understand the project structure
- Greps through the codebase to find relevant functions
- Re-reads the same files it already read last session
- Receives large raw outputs from every tool it calls (JSON, logs, markdown)

This is massively wasteful. **On a medium project, just the exploration phase burns ~18,000 tokens before Claude writes a single line of code.**

---

## The solution

ClaudeVault is a native macOS menubar app that acts as a **persistent memory and token optimization layer** for Claude Code.

It exposes a local MCP server that Claude discovers automatically at startup. Instead of re-reading files, Claude reads compact structured notes. Instead of grepping source files, it runs BM25 semantic search over a pre-built code index. Instead of receiving raw tool outputs, it gets compressed, cache-aligned responses.

**The result: 9× fewer tokens consumed per session.**

---

## How it works

![Architecture](assets/architecture.png)

ClaudeVault runs as a macOS menubar app. At startup it writes an auto-discovery lock file — Claude Code picks it up and connects via WebSocket. From that point on, Claude has access to 10 MCP tools covering memory, code search, and compression.

```
~/.config/claude/ide/claudevault.lock
{ "pid": 12345, "wsPort": 9876, "httpPort": 9877, "version": "1.0" }
```

Storage lives entirely on disk as plain Markdown files — no database, no sync, no cloud:

```
~/.claudevault/
└── my-project/
    ├── .project.json          ← project metadata
    ├── savings.json           ← cumulative token savings tracker
    └── notes/
        ├── context.md         ← hot cache: recent decisions + state
        ├── architecture.md
        └── decisions.md
```

---

## Token savings

### Per session — same project, same task

![Token comparison](assets/token-comparison.svg)

| What Claude does | Without ClaudeVault | With ClaudeVault | Reduction |
|---|---|---|---|
| Understand project structure | ~7,500 tokens (read files) | ~300 tokens (read context note) | **96%** |
| Find relevant functions | ~4,500 tokens (grep + Read) | ~200 tokens (`search_code`) | **96%** |
| Re-read previously seen context | ~3,000 tokens | ~0 tokens (KV cache hit) | **100%** |
| Process tool outputs (JSON/logs) | ~3,000 tokens (raw) | ~800 tokens (compressed) | **73%** |
| **Total** | **~18,000 tokens** | **~1,900 tokens** | **89%** |

### By feature

![Savings breakdown](assets/savings-breakdown.svg)

### Over 30 days (5 sessions/day)

![Monthly projection](assets/monthly-projection.svg)

| | Without ClaudeVault | With ClaudeVault |
|---|---|---|
| Tokens / month | ~2,700,000 | ~285,000 |
| Cost / month (Sonnet) | ~$8.10 | ~$0.86 |
| **Monthly savings** | | **$7.24 per developer** |

> Costs based on Claude Sonnet input pricing ($3 / 1M tokens). Savings scale linearly with usage — a team of 5 developers saves ~**$435/year**.

---

## Features

### 1. Persistent project memory

Claude reads your `context.md` note at the start of every session — getting a full picture of the project state, recent decisions, open bugs, and next steps in **~300 tokens** instead of rereading files.

```markdown
---
title: context
tags: [context]
updatedAt: 2026-06-15T18:00:00Z
---

## Current state
- MCP server running on :9876 (WebSocket) and :9877 (HTTP/SSE)
- BM25 code index built — 422,000 chunks across 3,200 files
- Bug: lock file not created on first run — sandbox permissions issue

## Last session
Implemented token savings tracker. Fixed List(selection:) nil warning.
Next: debug lock file creation, add savings to MenuBarExtra.
```

Notes use `[[Wikilink]]` syntax for cross-references and standard YAML frontmatter.

---

### 2. BM25 code search — `search_code`

The single most impactful feature. Instead of `grep + Read file`, Claude calls `search_code("concept")` which returns matching function bodies **inline**, ranked by relevance.

```
Tool: search_code(project: "my-app", query: "websocket handshake", topK: 5)

▸ MCP/MCPServer.swift:34 · function performHandshake [score:4.81]
func performHandshake(connection: NWConnection) async {
    // Read HTTP upgrade request, extract Sec-WebSocket-Key
    let key = extractKey(from: request)
    let accept = base64(sha1(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
    ...
}
```

**Token cost:** `search_code` returns exactly the matching functions. No noise, no surrounding code.

| Method | Tokens | What you get |
|---|---|---|
| `grep -r "handshake" . && Read file` | ~1,500 | Entire file (200–500 lines) |
| `search_code("websocket handshake")` | ~80–200 | Matching functions only |
| **Reduction** | **10–20×** | |

#### How the tokenizer works

The BM25 tokenizer expands camelCase and snake_case automatically:

```
"fetchUserProfile"    → [fetch, user, profile, fetchuserprofile]
"websocket_handshake" → [websocket, handshake]
```

**This means you query with natural words, not exact symbol names:**

```
✓ search_code("websocket handshake")   → finds performHandshake, handleWsUpgrade…
✓ search_code("json compress array")   → finds SmartCrusher.crush, compressJSON…
✓ search_code("auth token expire")     → finds checkTokenExpiry, invalidateSession…
✗ search_code("performWebSocketHandshake") → too specific, misses synonyms
```

Results are ranked by BM25 score. Score > 3.0 = strong match. Large chunks (> 80 lines) are automatically offloaded via CCR and retrieved on demand.

The index covers the full codebase — functions, classes, structs, enums, extensions across Swift, TypeScript, JavaScript, Python, Go, Rust, Kotlin. Indexing is done once via the app UI and persisted to disk.

---

### 3. SmartCrusher — JSON array compression

When Claude receives a JSON array from any tool (GitHub PR list, Linear issues, Slack messages…), SmartCrusher converts it from verbose JSON to a compact columnar table:

**Before (raw JSON):**
```json
[
  {"id": "PR-1", "title": "Fix auth bug", "status": "open", "author": "alice", "comments": 3},
  {"id": "PR-2", "title": "Add dark mode", "status": "merged", "author": "bob", "comments": 7},
  ...100 more items
]
```

**After (SmartCrusher):**
```
cols: id | title | status | author | comments
PR-1 | Fix auth bug | open | alice | 3
PR-2 | Add dark mode | merged | bob | 7
... [<<ccr:a3f9b2 98 rows>>]
```

**Savings: 40–70% on typical JSON arrays. Up to 92% on large result sets** (100+ items with repeated keys).

Rows beyond the inline threshold (8 by default) are offloaded to CCR — Claude only retrieves them if it actually needs them.

---

### 4. KV Cache Alignment — CacheAligner

Anthropic's API maintains a 5-minute KV cache on prompt prefixes. If the start of your prompt is identical between calls, the cached prefix is reused — **at zero token cost**.

CacheAligner ensures `get_project_context` always returns **byte-identical output** when project notes haven't changed, by hashing the content and caching the formatted response for 270 seconds (within the 5-minute KV cache window).

```
Call 1 → full response computed, cached internally (270s TTL)
Call 2 (same notes) → same bytes returned → Anthropic KV cache hit → 0 tokens
Call 3 (note changed) → recomputed, new cache entry
```

**For repeated calls to `get_project_context` within a session: effectively free.**

---

### 5. CCR — Content-Chunked Retrieval

Large content is never returned in full unless Claude actually needs it. Instead, ClaudeVault offloads content beyond a threshold to an in-memory store and returns a marker:

```
▸ architecture [architecture,mcp] 06-15
## Overview
ClaudeVault is a macOS menubar app exposing an MCP server...
[first 40 lines inline]

<<ccr:a3f9b2c1d4e5 87 lines>>
```

Claude calls `retrieve(hash: "a3f9b2c1d4e5")` only if it needs the full content. **Most of the time, it doesn't.**

This applies to: notes longer than 80 lines, large codebase indexes (> 120 files), code chunks over 80 lines, and any large tool output passed through `compress`.

---

### 6. Universal compress tool

The `compress` tool is a **headroom-style proxy** — Claude can pass any large tool output through it before processing:

```
Tool: compress(content: <2,000-line build log>)

[compress:log ~84%↓ 8000→1280 tokens saved≈6720]
ERROR: Build failed — missing framework 'ClaudeVaultKit'
  → ClaudeVault/App/ClaudeVaultApp.swift:12
WARNING: Deprecated API 'NSStatusItem.length' at MenuBarView.swift:34
[3 errors · 12 warnings · INFO/DEBUG dropped]
<<ccr:f7a1b3 1847 lines>>
```

| Content type | Typical reduction |
|---|---|
| JSON arrays (GitHub, Linear, Slack) | 40–70% |
| Build logs / test output | 70–85% |
| Large markdown documents | 30–50% |
| Raw grep output | 50–75% |

Auto-detects content type. Pass `type: "json"` / `"log"` / `"markdown"` to override.

---

### 7. Token savings tracker

Every `search_code` call logs the delta between what it cost (`chars returned / 4`) vs what the alternative would have cost (reading each unique file in full). The cumulative counter is visible in the app and persists across sessions.

```
Project: my-app
├── 2,847,234 tokens saved
├── 1,247 search_code calls
└── ≈ 14× context windows worth of savings
```

---

## MCP Tools reference

| Tool | Description | Token cost |
|---|---|---|
| `get_project_context` | Load project notes + context. **Call first every session.** | ~300 tok |
| `list_notes` | List all notes with title, tags, updatedAt | ~50 tok |
| `read_note` | Read a specific note's full content | ~note size |
| `write_note` | Create or update a note (Markdown + YAML frontmatter) | ~10 tok |
| `search_notes` | Full-text search across all notes | ~100 tok |
| `search_code` | **BM25 semantic search over indexed code** | ~80–200 tok |
| `read_chunk` | Read a specific chunk by file + line | ~chunk size |
| `index_codebase` | Compact symbol map (names + line numbers) | ~200 tok |
| `compress` | Compress any tool output (JSON/log/markdown) | −40–85% |
| `retrieve` | Fetch CCR-offloaded content by hash | on demand |

### Startup prompt (built into `get_project_context`)

```
══ TOKEN BUDGET — read this once, apply always ══

1. CODE SEARCH (when indexedAt is set)
   search_code("natural words") → BM25 over ALL indexed functions/classes/structs
   NEVER use Bash grep + Read file when the index exists.

2. COMPRESS LARGE TOOL OUTPUTS
   When any MCP tool returns > 200 lines: compress(content: "…") first.

3. CCR MARKERS
   <<ccr:HASH N_lines>> = offloaded content. Call retrieve(hash) ONLY if needed.

4. CACHE
   Call get_project_context with identical args → guaranteed KV cache hit (270s TTL).

5. END OF SESSION
   Always write_note(title:"context", body:"…") to persist session state.
```

---

## Transport protocols

### WebSocket — Claude Code (port 9876)

JSON-RPC 2.0 over WebSocket with manual framing (Network.framework, no dependencies):

1. TCP → extract `Sec-WebSocket-Key` → respond `101 Switching Protocols`
2. SHA1 via `CryptoKit.Insecure.SHA1` → base64 `Sec-WebSocket-Accept`
3. Frame parser: FIN/opcode/mask/length, XOR payload with masking key
4. Opcodes: `0x1` text · `0x8` close · `0x9` ping → pong `0xA`

### HTTP/SSE — Claude Desktop (port 9877)

- `POST /message` → receives JSON-RPC, returns JSON response
- `GET /sse` → server-sent events stream for server→client notifications

---

## UI

The app uses a native 3-column NavigationSplitView (projects → notes → editor), a MenuBarExtra for quick access, and a project home view with three tabs:

**Overview** — project stats, index status, RAG pipeline diagram, token savings counter.

**Graph** — force-directed graph of the top 90 most important code chunks. Nodes are clustered by file. Alpha-cooling ensures the graph settles automatically (no jitter). Edges: gray = same file, purple = shared semantic tokens between files.

**RAG Explorer** — live BM25 search with a file sidebar, chunk browser (top 200 by importance score by default), and expandable code preview with line numbers.

---

## Build

Requirements: macOS 26.4+, Xcode 26.5+

```bash
# Build release
make build

# Create distributable DMG
make dmg

# Generate app icon from 1024×1024 source
make icons

# Clean
make clean
```

Sandbox must be disabled (`ENABLE_APP_SANDBOX = NO` in build settings) to allow writing to `~/.claudevault/` and `~/.config/claude/ide/`.

---

## Storage format

Every note is a plain Markdown file with YAML frontmatter:

```markdown
---
title: Architecture
tags: [architecture, mcp, swift]
status: mature
updatedAt: 2026-06-15T18:00:00Z
---

## Overview
ClaudeVault exposes an MCP server over WebSocket (:9876) and HTTP/SSE (:9877).

## Key decisions
- No external dependencies — Network.framework + CryptoKit only
- Storage: plain Markdown files in ~/.claudevault/<slug>/notes/
- [[Decisions]] for the rationale behind each choice
```

`[[Wikilink]]` syntax is supported for cross-referencing notes.

---

## Roadmap

- [ ] Debug auto-discovery lock file on first launch
- [ ] Token savings counter in MenuBarExtra popover
- [ ] ProseCompressor — extract signal sentences from long notes
- [ ] Adaptive `topK` in `search_code` based on BM25 score distribution
- [ ] Cross-session note deduplication

---

<div align="center">
  <sub>Built with Swift 6 · SwiftUI · Network.framework · CryptoKit · Zero dependencies</sub>
</div>
