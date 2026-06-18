import Testing
import Foundation
@testable import ContextVault

// Real token-consumption comparison: same task, same model, same codebase.
//
// WITHOUT ContextVault — agent has list_directory + read_file + search_file_content.
//   This is how Claude Code and other agents actually explore codebases:
//   they grep for patterns, list dirs, and read relevant files one at a time.
//   Token cost = every file read in full + all directory listings + search results.
//
// WITH ContextVault — agent has get_project_context + search_code + compress.
//   It retrieves only the relevant BM25 chunks — typically 3-5 targeted excerpts.
//
// Both use the OpenAI API (gpt-4o-mini). Set OPENAI_API_KEY to enable.
@Suite("Agent loop — real token comparison WITH vs WITHOUT ContextVault")
struct AgentLoopTests {

    let codebaseRoot: URL
    let vault: VaultManager
    let tools: MCPTools
    let project: Project

    init() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cv-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        codebaseRoot = try FakeCodebase.create(in: dir)
        vault = VaultManager(root: dir.appendingPathComponent("vault"))
        project = Project(id: UUID(), name: "MyApp", rootPath: codebaseRoot.path)
        try vault.addProject(project)
        try vault.writeNote(SeedData.contextNote, to: project)
        try vault.writeNote(SeedData.architectureNote, to: project)

        let result = CodeChunker.chunkProject(at: codebaseRoot.path)
        CodeRAGManager.shared.inject(index: BM25Index(chunks: result.chunks), for: project.slug)
        tools = MCPTools(vault: vault)
    }

    // MARK: - Main comparison test

    @Test func compareTokenConsumptionWithAndWithoutContextVault() async throws {
        guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
            print("⏭  OPENAI_API_KEY not set — skipping real API comparison test")
            return
        }
        let client = OpenAIClient(apiKey: apiKey)

        // Task that requires reading multiple files across Auth, Network, and Session layers.
        // A real agent cannot answer this from a single file — it must grep + read 4-6 files.
        let task = """
        I'm debugging a production bug in the MyApp Swift project at \(codebaseRoot.path). \
        Users are getting logged out unexpectedly after token rotation on mobile. \
        I need you to trace the complete token lifecycle:
        1. How are JWT access tokens generated and what is their TTL?
        2. How are refresh tokens stored securely (what storage mechanism)?
        3. How does the network layer handle 401 responses — what triggers token refresh?
        4. How does token rotation work and what race condition could cause double-rotation?
        5. What happens to the user session when rotation fails?
        List the exact function names involved in each step.
        """

        print("\n══ WITHOUT ContextVault (file exploration tools) ══════════")
        let without = try await client.runWithFileExplorationTools(task: task, codebaseRoot: codebaseRoot)
        printRun(without, label: "WITHOUT")

        print("\n══ WITH ContextVault (BM25 search tools) ══════════════════")
        let with_ = try await client.runWithContextVault(task: task, tools: tools, project: project)
        printRun(with_, label: "WITH")

        let savings    = without.promptTokens - with_.promptTokens
        let savingsPct = Int(Double(savings) / Double(max(1, without.promptTokens)) * 100)
        let ratio      = Double(without.promptTokens) / Double(max(1, with_.promptTokens))

        print("""

        ══ RESULTS ════════════════════════════════════════════
        WITHOUT ContextVault:  \(without.promptTokens) prompt tokens  (\(without.toolCalls.count) tool calls)
        WITH ContextVault:     \(with_.promptTokens) prompt tokens  (\(with_.toolCalls.count) tool calls)
        ──────────────────────────────────────────────────────
        Saved: \(savings) tokens — \(savingsPct)% — \(String(format: "%.1f", ratio))× fewer
        ══════════════════════════════════════════════════════
        """)

        #expect(with_.promptTokens < without.promptTokens,
            "ContextVault must use fewer tokens than file exploration (\(with_.promptTokens) vs \(without.promptTokens))")
        #expect(ratio >= 1.5,
            "Expected at least 1.5× savings, got \(String(format: "%.1f", ratio))×")
        #expect(!with_.finalAnswer.isEmpty,  "WITH run must produce an answer")
        #expect(!without.finalAnswer.isEmpty, "WITHOUT run must produce an answer")
    }

    // MARK: - Individual scenarios (run standalone to inspect behavior)

    @Test func withoutContextVaultExploresWithTools() async throws {
        guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
            print("⏭  OPENAI_API_KEY not set — skipping"); return
        }
        let client = OpenAIClient(apiKey: apiKey)
        let result = try await client.runWithFileExplorationTools(
            task: "List all Swift files in the Sources/Auth directory and describe what each one does.",
            codebaseRoot: codebaseRoot
        )
        printRun(result, label: "WITHOUT (directory exploration)")
        #expect(!result.finalAnswer.isEmpty)
        // Agent must use at least 2 tool calls (list_directory + at least one read or search)
        #expect(result.toolCalls.count >= 2, "Agent must call multiple tools to explore the codebase")
    }

    @Test func withContextVaultSearchesIndex() async throws {
        guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
            print("⏭  OPENAI_API_KEY not set — skipping"); return
        }
        let client = OpenAIClient(apiKey: apiKey)
        let result = try await client.runWithContextVault(
            task: "Find where refresh token rotation is implemented in \(codebaseRoot.path). Show the function name and explain what race condition protection it has.",
            tools: tools, project: project
        )
        printRun(result, label: "WITH (token rotation search)")
        #expect(!result.finalAnswer.isEmpty)
        #expect(result.toolCalls.contains("search_code"),
            "Agent must use search_code instead of reading files")

        let lower = result.finalAnswer.lowercased()
        #expect(lower.contains("rotate") || lower.contains("rotation") || lower.contains("refresh"),
            "Answer should mention token rotation")
    }

    // MARK: - Helper

    private func printRun(_ r: AgentRunResult, label: String) {
        print("  Tools used:     \(r.toolCalls.joined(separator: " → "))")
        print("  Turns:          \(r.turns)")
        print("  Prompt tokens:  \(r.promptTokens)")
        print("  Answer:         \(r.finalAnswer.prefix(200).replacingOccurrences(of: "\n", with: " "))")
    }
}

// MARK: - Result type

struct AgentRunResult {
    let turns:            Int
    let toolCalls:        [String]
    let promptTokens:     Int
    let completionTokens: Int
    let finalAnswer:      String
    var totalTokens: Int { promptTokens + completionTokens }
}

// MARK: - OpenAI client

struct OpenAIClient {
    let apiKey: String
    let model:  String

    init(apiKey: String, model: String = "gpt-4o-mini") {
        self.apiKey = apiKey
        self.model  = model
    }

    // MARK: - WITHOUT ContextVault: agent uses file exploration tools
    //
    // This is how real agents (Claude Code, Cursor, Copilot) work:
    // they call list_directory to discover the layout, grep to find patterns,
    // and read_file to load the relevant files. Token cost grows linearly with
    // the number and size of files the agent chooses to read.

    func runWithFileExplorationTools(
        task: String,
        codebaseRoot: URL,
        maxTurns: Int = 15
    ) async throws -> AgentRunResult {
        let explorationTools = [
            openAITool(
                name: "list_directory",
                description: "List the files and subdirectories at the given path. Use this first to understand the project layout.",
                parameters: [
                    "path": ["type": "string", "description": "Absolute path to the directory to list"],
                ]
            ),
            openAITool(
                name: "read_file",
                description: "Read the full content of a source file. Use this to understand implementations in detail.",
                parameters: [
                    "path": ["type": "string", "description": "Absolute path to the file to read"],
                ]
            ),
            openAITool(
                name: "search_file_content",
                description: "Search for a text pattern across all files in a directory (like grep). Returns matching lines with filename and line number. Use this to locate functions or keywords without reading entire files.",
                parameters: [
                    "directory":       ["type": "string", "description": "Root directory to search in"],
                    "pattern":         ["type": "string", "description": "Text pattern to search for (case-insensitive)"],
                    "file_extension":  ["type": "string", "description": "Only search files with this extension (e.g. 'swift')"],
                ]
            ),
        ]

        let systemPrompt = """
        You are a Swift expert helping to debug a production issue. \
        You have access to the project filesystem via tools. \
        Start by listing the directory structure to understand the layout, \
        then grep for relevant patterns and read the specific files you need. \
        You MUST use tools to explore the codebase — do not answer from general knowledge.
        """

        return try await runLoop(
            messages: [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": task],
            ],
            tools: explorationTools,
            maxTurns: maxTurns
        ) { name, args in
            switch name {
            case "list_directory":
                let path = args["path"] as? String ?? codebaseRoot.path
                return Self.listDirectory(path)
            case "read_file":
                let path = args["path"] as? String ?? ""
                return Self.readFile(path)
            case "search_file_content":
                let dir  = args["directory"]      as? String ?? codebaseRoot.path
                let pat  = args["pattern"]        as? String ?? ""
                let ext  = args["file_extension"] as? String ?? "swift"
                return Self.searchFiles(in: dir, pattern: pat, extension: ext)
            default:
                return "Unknown tool: \(name)"
            }
        }
    }

    // MARK: - WITH ContextVault: agent uses get_project_context + search_code + compress

    func runWithContextVault(
        task: String,
        tools mcpTools: MCPTools,
        project: Project,
        maxTurns: Int = 8
    ) async throws -> AgentRunResult {
        let cvTools = [
            openAITool(
                name: "get_project_context",
                description: "CALL THIS FIRST. Returns project notes and code index summary. Costs ~200 tokens instead of thousands to read files.",
                parameters: ["path": ["type": "string", "description": "Your current working directory"]]
            ),
            openAITool(
                name: "search_code",
                description: "BM25 semantic search over the indexed codebase. Returns the most relevant function bodies. 10-20× cheaper than read_file because it returns only matching chunks.",
                parameters: [
                    "project": ["type": "string", "description": "Project slug (from get_project_context)"],
                    "query":   ["type": "string", "description": "Natural language search query"],
                    "topK":    ["type": "integer", "description": "Max results to return (default 5)"],
                ]
            ),
            openAITool(
                name: "compress",
                description: "Compress any large content before returning it to reduce token usage by 40-70%.",
                parameters: [
                    "content": ["type": "string"],
                    "type":    ["type": "string", "enum": ["json", "log", "markdown", "code"]],
                ]
            ),
        ]

        return try await runLoop(
            messages: [["role": "user", "content": task]],
            tools: cvTools,
            maxTurns: maxTurns
        ) { name, args in
            let result = mcpTools.handle(name: name, arguments: args)
            return result.content
        }
    }

    // MARK: - Core agentic loop

    private func runLoop(
        messages initialMessages: [[String: Any]],
        tools: [[String: Any]],
        maxTurns: Int,
        executor: (String, [String: Any]) -> String
    ) async throws -> AgentRunResult {
        var messages    = initialMessages
        var turns       = 0
        var toolCalls:  [String] = []
        var totalPrompt = 0
        var totalComp   = 0
        var finalAnswer = ""

        while turns < maxTurns {
            turns += 1
            let response = try await callChatAPI(messages: messages, tools: tools)
            totalPrompt += response.promptTokens
            totalComp   += response.completionTokens

            if response.toolCalls.isEmpty {
                finalAnswer = response.textContent
                break
            }

            // Append the assistant's turn (with tool_calls field)
            var assistantMsg: [String: Any] = ["role": "assistant"]
            if !response.textContent.isEmpty { assistantMsg["content"] = response.textContent }
            assistantMsg["tool_calls"] = response.toolCalls.map { tc -> [String: Any] in
                ["id": tc.id, "type": "function",
                 "function": ["name": tc.name, "arguments": tc.rawArguments]]
            }
            messages.append(assistantMsg)

            // Execute each tool and append results
            for tc in response.toolCalls {
                toolCalls.append(tc.name)
                let args   = parseJSON(tc.rawArguments)
                print("  🔧 \(tc.name)(\(describeArgs(args)))")
                let result = executor(tc.name, args)
                let preview = result.prefix(150).replacingOccurrences(of: "\n", with: "↵")
                print("  ↳ \(preview)\(result.count > 150 ? "…" : "") [\(result.count) chars]")
                messages.append(["role": "tool", "tool_call_id": tc.id, "content": result])
            }
        }

        return AgentRunResult(
            turns: turns,
            toolCalls: toolCalls,
            promptTokens: totalPrompt,
            completionTokens: totalComp,
            finalAnswer: finalAnswer
        )
    }

    // MARK: - Filesystem tool implementations

    private static func listDirectory(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return "Error: cannot list '\(path)'" }

        let sorted = entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let lines = sorted.map { entry -> String in
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDir ? "\(entry.lastPathComponent)/" : entry.lastPathComponent
        }
        return "Contents of \(path):\n" + lines.joined(separator: "\n")
    }

    private static func readFile(_ path: String) -> String {
        guard !path.isEmpty else { return "Error: empty path" }
        let url = URL(fileURLWithPath: path)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return "Error: cannot read '\(path)'"
        }
        return "File: \(path)\n\(content)"
    }

    private static func searchFiles(in dirPath: String, pattern: String, extension ext: String) -> String {
        guard !pattern.isEmpty else { return "Error: empty search pattern" }
        let url = URL(fileURLWithPath: dirPath)
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return "Error: cannot enumerate '\(dirPath)'" }

        var results: [String] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == ext else { continue }
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let lines = content.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                if line.range(of: pattern, options: [.caseInsensitive]) != nil {
                    let rel = fileURL.path.replacingOccurrences(of: dirPath + "/", with: "")
                    results.append("\(rel):\(i + 1):\t\(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        if results.isEmpty { return "No matches for '\(pattern)' in \(dirPath)" }
        // Cap at 60 results to avoid overwhelming the context
        let truncated = results.count > 60
        let output = results.prefix(60).joined(separator: "\n")
        return output + (truncated ? "\n[\(results.count - 60) more matches truncated]" : "")
    }

    // MARK: - HTTP

    private struct ChatResponse {
        let textContent:      String
        let toolCalls:        [ToolCall]
        let promptTokens:     Int
        let completionTokens: Int
    }

    private struct ToolCall {
        let id:           String
        let name:         String
        let rawArguments: String
    }

    private func callChatAPI(messages: [[String: Any]], tools: [[String: Any]]) async throws -> ChatResponse {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json",  forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = ["model": model, "messages": messages]
        if !tools.isEmpty { body["tools"] = tools }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, httpResponse) = try await URLSession.shared.data(for: req)
        guard let http = httpResponse as? HTTPURLResponse, http.statusCode == 200 else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw OpenAIError.apiError(raw)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenAIError.invalidResponse
        }

        let usage         = json["usage"]   as? [String: Any] ?? [:]
        let promptTok     = usage["prompt_tokens"]     as? Int ?? 0
        let completionTok = usage["completion_tokens"] as? Int ?? 0

        let choices  = json["choices"]  as? [[String: Any]] ?? []
        let message  = choices.first?["message"] as? [String: Any] ?? [:]
        let text     = message["content"]    as? String ?? ""
        let rawCalls = message["tool_calls"] as? [[String: Any]] ?? []

        let calls = rawCalls.compactMap { tc -> ToolCall? in
            guard let id   = tc["id"]       as? String,
                  let fn   = tc["function"] as? [String: Any],
                  let name = fn["name"]     as? String,
                  let args = fn["arguments"] as? String
            else { return nil }
            return ToolCall(id: id, name: name, rawArguments: args)
        }

        return ChatResponse(
            textContent:      text,
            toolCalls:        calls,
            promptTokens:     promptTok,
            completionTokens: completionTok
        )
    }

    // MARK: - Tool definition builder (OpenAI format)

    private func openAITool(name: String, description: String, parameters: [String: Any]) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name":        name,
                "description": description,
                "parameters": [
                    "type":       "object",
                    "properties": parameters,
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    // MARK: - Helpers

    private func parseJSON(_ raw: String) -> [String: Any] {
        guard let data = raw.data(using: .utf8),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    private func describeArgs(_ args: [String: Any]) -> String {
        args.map { k, v in "\(k): \"\(String(describing: v).prefix(50))\"" }.joined(separator: ", ")
    }
}

enum OpenAIError: Error {
    case apiError(String)
    case invalidResponse
}
