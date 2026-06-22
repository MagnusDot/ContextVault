#!/usr/bin/env python3
"""
ContextVault benchmark — coding tasks WITH vs WITHOUT ContextVault.

Both arms receive identical coding tasks on the target project.

WITHOUT: agent explores codebase via list_directory / read_file / search_file_content
WITH:    agent uses ContextVault MCP (get_project_context / search_code / read_note)

We measure total *prompt* tokens consumed until the agent outputs a solution.
The agent has no write tools — it just produces code as text.

Usage:
    OPENAI_API_KEY=sk-... python3 scripts/benchmark.py --project claudevault
    OPENAI_API_KEY=sk-... python3 scripts/benchmark.py --project claudevault --runs 2 --tasks add-tool,fix-bug
"""

import argparse, json, os, statistics, sys, urllib.request
from pathlib import Path

# ── Config ───────────────────────────────────────────────────────────────────

MCP_HTTP   = "http://localhost:9877"
OPENAI_URL = "https://api.openai.com/v1/chat/completions"
VAULT_ROOT = Path.home() / ".contextvault"


# ── Project discovery ─────────────────────────────────────────────────────────

def discover_project(slug: str) -> tuple[str, str]:
    config = VAULT_ROOT / slug / ".project.json"
    if not config.exists():
        available = [d.name for d in VAULT_ROOT.iterdir() if (d / ".project.json").exists()] if VAULT_ROOT.exists() else []
        sys.exit(f"Project '{slug}' not found.\nAvailable: {available or '(none)'}")
    data = json.loads(config.read_text())
    root = data.get("rootPath", "").rstrip("/")
    if not root or not Path(root).is_dir():
        sys.exit(f"rootPath '{root}' doesn't exist on disk.")
    return root, slug


# ── MCP client ────────────────────────────────────────────────────────────────

def mcp_call(method: str, params: dict, timeout: int = 30) -> dict:
    body = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": 1}).encode()
    req = urllib.request.Request(f"{MCP_HTTP}/mcp", data=body,
                                 headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())

def check_mcp() -> bool:
    try:
        r = mcp_call("initialize", {
            "protocolVersion": "2024-11-05", "capabilities": {},
            "clientInfo": {"name": "benchmark", "version": "1.0"},
        }, timeout=5)
        return "result" in r
    except Exception:
        return False

def mcp_tool(name: str, args: dict) -> str:
    try:
        r = mcp_call("tools/call", {"name": name, "arguments": args})
        content = r.get("result", {}).get("content", [])
        if isinstance(content, list):
            return " ".join(c.get("text", "") for c in content)
        return str(r.get("result", r))
    except Exception as e:
        return f"[MCP error: {e}]"


# ── OpenAI loop ───────────────────────────────────────────────────────────────

def chat(api_key: str, model: str, messages: list, tools: list) -> dict:
    payload: dict = {"model": model, "messages": messages}
    if tools:
        payload["tools"] = tools
    req = urllib.request.Request(OPENAI_URL, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json",
                                          "Authorization": f"Bearer {api_key}"}, method="POST")
    with urllib.request.urlopen(req, timeout=600) as r:
        return json.loads(r.read())

def run_agent(api_key, model, task_prompt, tools_schema, executor,
              system="", max_turns=20) -> dict:
    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": task_prompt})

    total_prompt = total_comp = 0
    tool_calls_made = []
    final_answer = ""

    for turn in range(max_turns):
        resp = chat(api_key, model, messages, tools_schema)
        usage = resp.get("usage", {})
        total_prompt += usage.get("prompt_tokens", 0)
        total_comp   += usage.get("completion_tokens", 0)

        msg       = resp["choices"][0]["message"]
        raw_calls = msg.get("tool_calls") or []

        if not raw_calls:
            final_answer = msg.get("content", "")
            break

        messages.append(msg)
        for tc in raw_calls:
            name   = tc["function"]["name"]
            args   = json.loads(tc["function"]["arguments"])
            result = executor(name, args)
            tool_calls_made.append(name)
            print(f"    [{turn+1}] {name}({_fmt_args(args)}) → {len(result)}c")
            messages.append({"role": "tool", "tool_call_id": tc["id"], "content": result})

    return {
        "prompt_tokens":     total_prompt,
        "completion_tokens": total_comp,
        "tool_calls":        tool_calls_made,
        "final_answer":      final_answer,
    }

def _fmt_args(args: dict) -> str:
    parts = []
    for k, v in args.items():
        s = repr(str(v))
        parts.append(f"{k}={s[:35]}{'…' if len(str(v))>35 else ''}")
    return ", ".join(parts)


# ── WITHOUT arm: filesystem tools ────────────────────────────────────────────

def _list_dir(path: str) -> str:
    p = Path(path)
    if not p.exists(): return f"Error: not found: {path}"
    entries = sorted(p.iterdir(), key=lambda e: e.name)
    return f"{path}:\n" + "\n".join(
        (e.name + "/" if e.is_dir() else e.name) for e in entries
        if not e.name.startswith(".") and e.name not in ("DerivedData", ".build")
    )

def _read_file(path: str) -> str:
    try:   return Path(path).read_text(errors="replace")
    except Exception as e: return f"Error: {e}"

def _grep(directory: str, pattern: str, ext: str = "swift") -> str:
    results = []
    skip = {".build", "DerivedData", ".git"}
    for p in Path(directory).rglob(f"*.{ext}"):
        if any(s in p.parts for s in skip): continue
        try:
            for i, line in enumerate(p.read_text(errors="replace").splitlines(), 1):
                if pattern.lower() in line.lower():
                    results.append(f"{p.relative_to(directory)}:{i}: {line.strip()}")
        except Exception: pass
    if not results: return f"No matches for '{pattern}'"
    suffix = f"\n[{len(results)-80} more omitted]" if len(results) > 80 else ""
    return "\n".join(results[:80]) + suffix

FS_TOOLS = [
    {"type": "function", "function": {
        "name": "list_directory",
        "description": "List files and subdirectories at a path.",
        "parameters": {"type": "object", "required": ["path"],
                       "properties": {"path": {"type": "string"}}},
    }},
    {"type": "function", "function": {
        "name": "read_file",
        "description": "Read the full content of a file.",
        "parameters": {"type": "object", "required": ["path"],
                       "properties": {"path": {"type": "string"}}},
    }},
    {"type": "function", "function": {
        "name": "search_files",
        "description": "Search for a text pattern across source files (grep).",
        "parameters": {"type": "object", "required": ["directory", "pattern"], "properties": {
            "directory":      {"type": "string"},
            "pattern":        {"type": "string"},
            "file_extension": {"type": "string", "description": "Default: swift"},
        }},
    }},
]

def make_fs_executor(root: str):
    def execute(name, args):
        if name == "list_directory":  return _list_dir(args.get("path", root))
        if name == "read_file":       return _read_file(args.get("path", ""))
        if name == "search_files":    return _grep(args.get("directory", root),
                                                   args.get("pattern", ""),
                                                   args.get("file_extension", "swift"))
        return f"Unknown tool: {name}"
    return execute

FS_SYSTEM = (
    "You are an expert Swift engineer working on ContextVault, a macOS menubar app that exposes an MCP server.\n"
    "You are dropped into this project cold and must understand it before you can change it. Rules:\n"
    "- Build an understanding of the project's structure and components before writing code\n"
    "- Base your code on the ACTUAL source — do NOT invent function signatures or APIs\n"
    "- Tasks touch multiple files and don't name them: locate the relevant code yourself\n"
    "- Use the tools you have available as efficiently as possible — minimise redundant exploration\n"
    "- Output complete, compilable Swift code that follows the exact patterns in the codebase\n"
    "- Include ALL files that need to change, with signatures matching what you found"
)


# ── WITH arm: ContextVault MCP tools ─────────────────────────────────────────

CV_TOOLS = [
    {"type": "function", "function": {
        "name": "get_project_context",
        "description": "Call FIRST. Returns project notes + indexed code summary. Far cheaper than reading files.",
        "parameters": {"type": "object", "required": ["path"],
                       "properties": {"path": {"type": "string", "description": "Any path inside the project"}}},
    }},
    {"type": "function", "function": {
        "name": "search_code",
        "description": "BM25 search over indexed source code. Returns matching function/type bodies. Much cheaper than read_file.",
        "parameters": {"type": "object", "required": ["project", "query"], "properties": {
            "project": {"type": "string"},
            "query":   {"type": "string"},
            "topK":    {"type": "integer", "description": "Max results (default 5)"},
        }},
    }},
    {"type": "function", "function": {
        "name": "read_note",
        "description": "Read a specific project note (architecture, decisions, context, etc.).",
        "parameters": {"type": "object", "required": ["project", "title"], "properties": {
            "project": {"type": "string"},
            "title":   {"type": "string"},
        }},
    }},
    {"type": "function", "function": {
        "name": "read_file",
        "description": "Read a file when you need to see the full content (use after search_code narrows down the location).",
        "parameters": {"type": "object", "required": ["path"],
                       "properties": {"path": {"type": "string"}}},
    }},
]

def make_cv_executor(root: str):
    def execute(name, args):
        if name == "get_project_context":
            args.setdefault("path", root)
            return mcp_tool(name, args)
        if name == "read_file":
            return _read_file(args.get("path", ""))
        return mcp_tool(name, args)
    return execute

CV_SYSTEM = FS_SYSTEM


# ── Benchmark tasks ───────────────────────────────────────────────────────────

def make_tasks(root: str, slug: str) -> list[dict]:
    # COLD START — every task simulates a brand-new session with zero prior context.
    # Tasks describe the desired BEHAVIOR only; they do NOT name the files to change.
    # The agent must understand the project as a whole to locate the right code first.
    # This is the real value test: WITHOUT scans the codebase from scratch every time,
    # WITH gets global understanding from one get_project_context call.
    cold = (
        f"You are starting a BRAND NEW session on the Swift project at {root}, with zero prior "
        "knowledge of it. First understand the project as a whole, then locate the relevant code "
        "yourself — the task does NOT tell you which files to touch. Output complete, compilable "
        "Swift covering every file that must change, matching the project's existing patterns.\n\n"
    )
    return [
        {
            "id":     "new-mcp-tool-full",
            "prompt": cold + (
                "TASK: Add a new MCP tool `export_project` that exports all notes for a project as a single "
                "JSON object: {slug, name, rootPath, notes: [{title, tags, updatedAt, body}]}.\n"
                "A complete tool needs three things: the handler implementation, its JSON schema definition, "
                "and a unit test that calls it and verifies the JSON. Find where each of those lives and follow "
                "the existing pattern for the other tools."
            ),
            "check": lambda a: (
                "export_project" in a and
                ("inputSchema" in a or "description" in a or "MCPToolDefinitions" in a)
                and ("@Test" in a or "#expect" in a)
            ),
        },
        {
            "id":     "websocket-broadcast",
            "prompt": cold + (
                "TASK: When a note is created or updated through the `write_note` MCP tool, every connected "
                "WebSocket client should receive a JSON-RPC notification:\n"
                '  {"jsonrpc":"2.0","method":"notifications/note_updated","params":{"project":"<slug>","title":"<title>"}}\n'
                "Figure out how the WebSocket server manages its connections and encodes frames, and how the "
                "write_note tool is wired to it, then add the broadcast and the call site."
            ),
            "check": lambda a: (
                "broadcast" in a and
                "notification" in a.lower() and
                ("WebSocketConnection" in a or "NWConnection" in a or "sendFrame" in a or "connections" in a)
            ),
        },
        {
            "id":     "rate-limiter",
            "prompt": cold + (
                "TASK: Add rate limiting to the MCP HTTP server: max 30 requests/minute per client IP. "
                "Return HTTP 429 with a `Retry-After: 60` header when the limit is exceeded.\n"
                "Find the HTTP server, understand how it accepts connections and sends responses, then add a "
                "thread-safe limiter (per-IP counters protected by a lock) checked before routing."
            ),
            "check": lambda a: (
                "429" in a and
                "RateLimit" in a or "rateLimi" in a and
                ("NSLock" in a or "DispatchQueue" in a or "Dictionary" in a)
            ),
        },
        {
            "id":     "bm25-recency-boost",
            "prompt": cold + (
                "TASK: The code search doesn't account for file recency. Add a recency boost: chunks from files "
                "modified in the last 7 days should have their search score multiplied by 1.3.\n"
                "Find the chunk model, the code that builds chunks, and the search scoring function. You'll need "
                "to carry a file-modification date on each chunk and apply the multiplier during scoring."
            ),
            "check": lambda a: (
                ("fileModifiedAt" in a or "modifiedAt" in a or "modificationDate" in a) and
                ("1.3" in a or "recency" in a.lower() or "boost" in a.lower()) and
                "BM25" in a or "search(" in a
            ),
        },
        {
            "id":     "token-savings-mcp-tool",
            "prompt": cold + (
                "TASK: Add a new MCP tool `get_savings` that returns a project's token-savings stats: "
                "total tokens saved, number of MCP calls, and estimated cost saved (at $3 per 1M tokens), "
                "formatted like:\n"
                "  ⬡ claudevault savings: 42,000 tokens saved · 156 calls · ~$0.13 saved\n"
                "Find where per-project savings are already tracked, then add the tool following the same "
                "pattern as the existing tools (handler + schema definition)."
            ),
            "check": lambda a: (
                "get_savings" in a and
                ("TokenSavingsStore" in a or "savings" in a.lower()) and
                ("totalSaved" in a or "callCount" in a or "cost" in a.lower())
            ),
        },
    ]


# ── Results ───────────────────────────────────────────────────────────────────

def print_table(tasks, token_runs, correct_runs, n: int, out_path: str):
    W = 20
    lines = [
        f"\n══ BENCHMARK RESULTS  ({n} run{'s' if n>1 else ''}, median prompt tokens) ══════════════",
        f"  {'task':<{W}}  {'WITHOUT':>8}  {'WITH':>8}  {'saved':>7}  correct(with)",
        "  " + "─" * 62,
    ]
    sum_w = sum_c = n_correct = 0
    for t in tasks:
        wo = token_runs[t["id"]]["without"]
        wi = token_runs[t["id"]]["with"]
        mw = int(statistics.median(wo)) if wo else 0
        mc = int(statistics.median(wi)) if wi else 0
        pct  = int((mw - mc) / mw * 100) if mw else 0
        nc   = sum(correct_runs[t["id"]]["with"])
        flag = "✓" if nc > n / 2 else "✗"
        if nc > n / 2: n_correct += 1
        sum_w += mw; sum_c += mc
        lines.append(f"  {t['id']:<{W}}  {mw:>8}  {mc:>8}  {pct:>+6}%  {flag} {nc}/{n}")

    pct_total = int((sum_w - sum_c) / sum_w * 100) if sum_w else 0
    ratio     = sum_w / max(1, sum_c)
    lines += [
        "  " + "─" * 62,
        f"  {'TOTAL':<{W}}  {sum_w:>8}  {sum_c:>8}  {pct_total:>+6}%  ({ratio:.1f}× tokens WITH vs WITHOUT)",
        f"  {'Correctness':<{W}}  {n_correct}/{len(tasks)} tasks solved correctly WITH ContextVault",
        "══════════════════════════════════════════════════════════════\n",
    ]
    table = "\n".join(lines)
    print(table)
    Path(out_path).write_text(table)
    print(f"📄 Saved to {out_path}")


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description="Benchmark coding tasks WITH vs WITHOUT ContextVault")
    ap.add_argument("--project", required=True, help="ContextVault project slug")
    ap.add_argument("--runs",  type=int, default=1)
    ap.add_argument("--model", default="gpt-4o-mini")
    ap.add_argument("--out",   default="/tmp/cv-benchmark.txt")
    ap.add_argument("--tasks", help="Comma-separated task IDs (default: all)")
    args = ap.parse_args()

    api_key = os.environ.get("OPENAI_API_KEY") or sys.exit("Error: OPENAI_API_KEY not set")
    root, slug = discover_project(args.project)

    print(f"📂 Project : {slug}  →  {root}")
    print(f"🤖 Model   : {args.model}  ×  {args.runs} run(s) per arm")
    print(f"🔌 MCP at  : {MCP_HTTP} … ", end="", flush=True)
    if not check_mcp():
        print("❌  not reachable — is ContextVault running?"); sys.exit(1)
    print("✅")

    all_tasks = make_tasks(root, slug)
    if args.tasks:
        ids = set(args.tasks.split(","))
        all_tasks = [t for t in all_tasks if t["id"] in ids]
    if not all_tasks:
        sys.exit(f"No tasks matched. Available: {[t['id'] for t in make_tasks(root, slug)]}")

    total = len(all_tasks) * 2 * args.runs
    print(f"📊 {len(all_tasks)} tasks × 2 arms × {args.runs} runs = {total} API calls\n")

    token_runs   = {t["id"]: {"without": [], "with": []} for t in all_tasks}
    correct_runs = {t["id"]: {"without": [], "with": []} for t in all_tasks}
    done = 0

    fs_executor = make_fs_executor(root)
    cv_executor = make_cv_executor(root)

    for run in range(1, args.runs + 1):
        for task in all_tasks:

            # ── WITHOUT ──────────────────────────────────────────────────────
            done += 1
            print(f"\n╔═ [{done}/{total}] run {run}  WITHOUT  {task['id']} ═╗")
            r = run_agent(api_key, args.model, task["prompt"],
                          FS_TOOLS, fs_executor, system=FS_SYSTEM)
            ok = task["check"](r["final_answer"])
            token_runs[task["id"]]["without"].append(r["prompt_tokens"])
            correct_runs[task["id"]]["without"].append(ok)
            print(f"╚═ {'✓' if ok else '✗'}  prompt={r['prompt_tokens']}  comp={r['completion_tokens']}  "
                  f"turns={len(r['tool_calls'])}  [{' → '.join(dict.fromkeys(r['tool_calls']))}]")

            # ── WITH ─────────────────────────────────────────────────────────
            done += 1
            print(f"\n╔═ [{done}/{total}] run {run}  WITH     {task['id']} ═╗")
            r2 = run_agent(api_key, args.model, task["prompt"],
                           CV_TOOLS, cv_executor, system=CV_SYSTEM, max_turns=12)
            ok2 = task["check"](r2["final_answer"])
            token_runs[task["id"]]["with"].append(r2["prompt_tokens"])
            correct_runs[task["id"]]["with"].append(ok2)
            print(f"╚═ {'✓' if ok2 else '✗'}  prompt={r2['prompt_tokens']}  comp={r2['completion_tokens']}  "
                  f"turns={len(r2['tool_calls'])}  [{' → '.join(dict.fromkeys(r2['tool_calls']))}]")

    print_table(all_tasks, token_runs, correct_runs, args.runs, args.out)

if __name__ == "__main__":
    main()
