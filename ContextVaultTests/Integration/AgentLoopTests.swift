import Testing
import Foundation
import os
@testable import ContextVault

// Benchmark inspired by Ponytail (github.com/DietrichGebert/ponytail):
//   - Three measurements per cell, median reported (configurable via BENCHMARK_REPEAT)
//   - Two arms: WITHOUT (file exploration tools) vs WITH (ContextVault BM25 tools)
//   - Five focused tasks, each with a correctness gate
//   - Token savings + correctness printed in a table
//
// WITHOUT arm simulates how real agents (Claude Code, Cursor, Copilot) work:
//   list_directory → search_file_content → read_file, one at a time.
//
// WITH arm uses ContextVault tools: get_project_context + search_code.
//
// Set OPENAI_API_KEY to enable; set BENCHMARK_REPEAT=N to control run count (default 3).
@Suite("Benchmark — token comparison WITH vs WITHOUT ContextVault")
struct AgentLoopTests {

    let codebaseRoot: URL
    let vault: VaultManager
    let tools: MCPTools
    let project: Project

    init() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cv-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        codebaseRoot = try FakeCodebase.create(in: dir)
        vault = VaultManager(root: dir.appendingPathComponent("vault"))
        project = Project(id: UUID(), name: "MyApp", rootPath: codebaseRoot.path)
        try vault.addProject(project)
        try vault.writeNote(SeedData.contextNote, to: project)
        try vault.writeNote(SeedData.architectureNote, to: project)

        let result = CodeChunker.chunkProject(at: codebaseRoot.path)
        let idx = BM25Index(chunks: result.chunks)
        CodeRAGManager.shared.inject(index: idx, for: project.slug)
        tools = MCPTools(vault: vault)

        testLog.section("AgentLoopTests")
        testLog.setup(files: FakeCodebase.files.count, chunks: idx.count, slug: project.slug)
    }

    // MARK: - Benchmark tasks (5, like Ponytail)

    struct BenchmarkTask {
        let id:     String
        let prompt: String
        let check:  CorrectnessCheck
    }

    struct CorrectnessCheck {
        // AND-of-OR: every group must contribute at least one matching keyword.
        let groups: [[String]]

        func passes(_ answer: String) -> Bool {
            let lower = answer.lowercased()
            return groups.allSatisfy { group in
                group.contains { lower.contains($0.lowercased()) }
            }
        }
    }

    func makeTasks() -> [BenchmarkTask] {
        let root = codebaseRoot.path
        return [
            BenchmarkTask(
                id: "token-rotation",
                prompt: "In the MyApp Swift project at \(root): where is refresh token rotation implemented? Name the exact function, explain the ordering that prevents replay attacks, and describe what happens when the same refresh token is used twice.",
                check: CorrectnessCheck(groups: [
                    ["rotateRefreshToken", "rotate", "rotation"],
                    ["revoke", "revokedAt", "replay", "theft", "reuse", "twice"],
                ])
            ),
            BenchmarkTask(
                id: "network-401",
                prompt: "In the MyApp Swift project at \(root): trace the complete flow when NetworkClient receives a 401 response. Which class intercepts it, what does it call, and how are concurrent 401s from two simultaneous requests handled?",
                check: CorrectnessCheck(groups: [
                    ["401", "unauthorized", "NetworkError"],
                    ["interceptor", "TokenRefreshInterceptor", "refreshToken"],
                    ["coalesce", "single", "one", "concurrent", "once"],
                ])
            ),
            BenchmarkTask(
                id: "token-storage",
                prompt: "In the MyApp Swift project at \(root): where and how are the access token and refresh token stored on device? List the exact storage keys used.",
                check: CorrectnessCheck(groups: [
                    ["keychain", "Keychain", "TokenStore"],
                    ["access_token", "refresh_token", "myapp.access", "myapp.refresh"],
                ])
            ),
            BenchmarkTask(
                id: "session-lifecycle",
                prompt: "In the MyApp Swift project at \(root): what does SessionManager.login() do with the token pair it receives, and what state does it transition through during a refresh? List all State enum cases involved.",
                check: CorrectnessCheck(groups: [
                    ["login", "SessionManager"],
                    ["state", "State", "refreshing", "authenticated", "unauthenticated"],
                ])
            ),
            BenchmarkTask(
                id: "token-ttl",
                prompt: "In the MyApp Swift project at \(root): what are the exact TTL values (in seconds or human-readable) for access tokens and refresh tokens? In which file and constant are they defined?",
                check: CorrectnessCheck(groups: [
                    ["15", "fifteen", "900"],
                    ["7", "seven", "604800"],
                    ["AuthService", "accessTokenTTL", "refreshTokenTTL"],
                ])
            ),
        ]
    }

    // MARK: - Main benchmark (N runs × 5 tasks × 2 arms)

    @Test func benchmarkAllTasks() async throws {
        guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
            testLog.skip("OPENAI_API_KEY not set — skipping benchmark")
            return
        }
        let repeatCount = Int(ProcessInfo.processInfo.environment["BENCHMARK_REPEAT"] ?? "") ?? 3
        let client  = OpenAIClient(apiKey: apiKey)
        let tasks   = makeTasks()
        testLog.info("benchmark: \(tasks.count) tasks × 2 arms × \(repeatCount) runs")

        // Storage: [taskId: [arm: [run results]]]
        var tokenRuns:  [String: [String: [Int]]]  = [:]
        var correctRuns:[String: [String: [Bool]]] = [:]
        for task in tasks {
            tokenRuns[task.id]   = ["without": [], "with": []]
            correctRuns[task.id] = ["without": [], "with": []]
        }

        let totalCalls = tasks.count * 2 * repeatCount
        var done = 0

        for run in 1...repeatCount {
            for task in tasks {
                // WITHOUT arm
                done += 1
                testLog.run(n: done, total: totalCalls, arm: "WITHOUT", task: task.id)
                let without = try await client.runWithFileExplorationTools(
                    task: task.prompt, codebaseRoot: codebaseRoot
                )
                let okWithout = task.check.passes(without.finalAnswer)
                tokenRuns[task.id]!["without"]!.append(without.promptTokens)
                correctRuns[task.id]!["without"]!.append(okWithout)
                testLog.correct(okWithout, task: "\(task.id) (without)")
                printCompactRun(without, correct: okWithout)

                // WITH arm
                done += 1
                testLog.run(n: done, total: totalCalls, arm: "WITH   ", task: task.id)
                let with_ = try await client.runWithContextVault(
                    task: task.prompt, tools: tools, project: project
                )
                let okWith = task.check.passes(with_.finalAnswer)
                tokenRuns[task.id]!["with"]!.append(with_.promptTokens)
                correctRuns[task.id]!["with"]!.append(okWith)
                testLog.tokens(without: without.promptTokens, with: with_.promptTokens)
                testLog.correct(okWith, task: task.id)
                printCompactRun(with_, correct: okWith)
            }
        }

        printResultsTable(tasks: tasks, tokenRuns: tokenRuns, correctRuns: correctRuns, n: repeatCount)

        // --- Assertions ---

        testLog.section("Benchmark assertions")

        // 1. WITH must use fewer tokens than WITHOUT on every task (median)
        for task in tasks {
            let medWithout = median(tokenRuns[task.id]!["without"]!)
            let medWith    = median(tokenRuns[task.id]!["with"]!)
            testLog.tokens(without: medWithout, with: medWith)
            #expect(medWith < medWithout,
                "[\(task.id)] WITH (\(medWith) tok) must be cheaper than WITHOUT (\(medWithout) tok)")
        }

        // 2. Aggregate ratio ≥ 1.5× across all tasks
        let totalWithout = tasks.reduce(0) { $0 + median(tokenRuns[$1.id]!["without"]!) }
        let totalWith    = tasks.reduce(0) { $0 + median(tokenRuns[$1.id]!["with"]!) }
        let ratio = Double(totalWithout) / Double(max(1, totalWith))
        testLog.info("aggregate ratio: \(String(format: "%.2f", ratio))×  (threshold 1.5×)")
        #expect(ratio >= 1.5, "Total savings must be ≥ 1.5×, got \(String(format: "%.2f", ratio))×")

        // 3. WITH must answer correctly on majority of tasks (≥ 3/5)
        let correctTasks = tasks.filter { task in
            let runs = correctRuns[task.id]!["with"]!
            return runs.filter { $0 }.count > runs.count / 2
        }
        testLog.info("correctness: \(correctTasks.count)/\(tasks.count) tasks passed")
        #expect(correctTasks.count >= 3,
            "WITH must answer ≥ 3/5 tasks correctly (got \(correctTasks.count)/\(tasks.count))")
    }

    // MARK: - Smoke tests (single run, no repeat)

    @Test func withoutContextVaultExploresWithTools() async throws {
        guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
            testLog.skip("OPENAI_API_KEY not set"); return
        }
        let client = OpenAIClient(apiKey: apiKey)
        testLog.section("withoutContextVaultExploresWithTools")
        let result = try await client.runWithFileExplorationTools(
            task: "List all Swift files in the Sources/Auth directory of the MyApp project at \(codebaseRoot.path) and describe what each one does in one sentence.",
            codebaseRoot: codebaseRoot
        )
        testLog.info("turns=\(result.turns)  tools=\(result.toolCalls.count)  prompt=\(result.promptTokens)tok")
        printCompactRun(result, correct: true)
        #expect(!result.finalAnswer.isEmpty)
        #expect(result.toolCalls.count >= 2, "Agent must call at least 2 tools to explore the codebase")
    }

    @Test func withContextVaultUsesSearchNotFileReads() async throws {
        guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
            testLog.skip("OPENAI_API_KEY not set"); return
        }
        let client = OpenAIClient(apiKey: apiKey)
        let task = makeTasks().first(where: { $0.id == "token-rotation" })!
        testLog.section("withContextVaultUsesSearchNotFileReads")
        let result = try await client.runWithContextVault(
            task: task.prompt, tools: tools, project: project
        )
        let correct = task.check.passes(result.finalAnswer)
        testLog.info("turns=\(result.turns)  tools=\(result.toolCalls.joined(separator:"→"))  prompt=\(result.promptTokens)tok")
        testLog.correct(correct, task: task.id)
        printCompactRun(result, correct: correct)
        #expect(!result.finalAnswer.isEmpty)
        #expect(result.toolCalls.contains("search_code"),
            "WITH agent must call search_code (got: \(result.toolCalls))")
        #expect(correct, "Answer must mention token rotation and revocation mechanism")
    }

    // MARK: - Helpers

    private func printCompactRun(_ r: AgentRunResult, correct: Bool) {
        let gate = correct ? "✓" : "✗"
        print("  \(gate) \(r.promptTokens) tok  \(r.toolCalls.count) tools  [\(r.toolCalls.prefix(5).joined(separator:"→"))]")
        print("  → \(r.finalAnswer.prefix(180).replacingOccurrences(of: "\n", with: " "))")
    }

    private func printResultsTable(
        tasks:       [BenchmarkTask],
        tokenRuns:   [String: [String: [Int]]],
        correctRuns: [String: [String: [Bool]]],
        n:           Int
    ) {
        let w = 22
        print("\n══ RESULTS (\(n) runs, median) ════════════════════════════════")
        print(String(format: "  %-\(w)s  %7s  %7s  %6s  correct(with)", "task", "WITHOUT", "WITH", "saved"))
        print("  " + String(repeating: "─", count: 60))

        var sumWithout = 0
        var sumWith    = 0
        var correctCount = 0

        for task in tasks {
            let mWithout = median(tokenRuns[task.id]!["without"]!)
            let mWith    = median(tokenRuns[task.id]!["with"]!)
            let pct      = mWithout > 0 ? Int(Double(mWithout - mWith) / Double(mWithout) * 100) : 0
            let correctWith  = correctRuns[task.id]!["with"]!.filter { $0 }.count
            let gateStr  = "\(correctWith)/\(n)"
            if correctWith > n / 2 { correctCount += 1 }
            sumWithout += mWithout
            sumWith    += mWith
            print(String(format: "  %-\(w)s  %7d  %7d  %5d%%  %@",
                task.id, mWithout, mWith, pct, gateStr))
        }

        let totalPct = sumWithout > 0 ? Int(Double(sumWithout - sumWith) / Double(sumWithout) * 100) : 0
        let totalRatio = Double(sumWithout) / Double(max(1, sumWith))
        print("  " + String(repeating: "─", count: 60))
        print(String(format: "  %-\(w)s  %7d  %7d  %5d%%  (\(String(format: "%.1f", totalRatio))× fewer)",
            "TOTAL (sum medians)", sumWithout, sumWith, totalPct))
        print(String(format: "  %-\(w)s  %s/%d tasks answered correctly with ContextVault",
            "Correctness:", "\(correctCount)", tasks.count))
        print("══════════════════════════════════════════════════════════════\n")
    }

    private func median(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        return s.count % 2 == 0 ? (s[s.count/2 - 1] + s[s.count/2]) / 2 : s[s.count/2]
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

    // MARK: - WITHOUT arm: file exploration tools (how Claude Code / Cursor actually works)

    func runWithFileExplorationTools(
        task: String,
        codebaseRoot: URL,
        maxTurns: Int = 15
    ) async throws -> AgentRunResult {
        let explorationTools = [
            openAITool(
                name: "list_directory",
                description: "List files and subdirectories at the given path. Use this first to understand the project structure.",
                parameters: ["path": ["type": "string", "description": "Absolute path to list"]]
            ),
            openAITool(
                name: "read_file",
                description: "Read the full content of a source file.",
                parameters: ["path": ["type": "string", "description": "Absolute path to the file"]]
            ),
            openAITool(
                name: "search_file_content",
                description: "Search for a text pattern across all files in a directory (like grep). Returns matching lines with file and line number.",
                parameters: [
                    "directory":      ["type": "string", "description": "Root directory to search in"],
                    "pattern":        ["type": "string", "description": "Text pattern to search for (case-insensitive)"],
                    "file_extension": ["type": "string", "description": "Filter by file extension, e.g. 'swift'"],
                ]
            ),
        ]

        return try await runLoop(
            messages: [
                ["role": "system", "content": "You are a Swift expert debugging a production issue. Use tools to explore the codebase. Start with list_directory to understand the layout, then search_file_content to locate relevant code, then read_file for full context. You MUST use tools — do not answer from general knowledge."],
                ["role": "user",   "content": task],
            ],
            tools: explorationTools,
            maxTurns: maxTurns
        ) { name, args in
            switch name {
            case "list_directory":
                return Self.listDirectory(args["path"] as? String ?? codebaseRoot.path)
            case "read_file":
                return Self.readFile(args["path"] as? String ?? "")
            case "search_file_content":
                return Self.searchFiles(
                    in:  args["directory"]      as? String ?? codebaseRoot.path,
                    pattern: args["pattern"]    as? String ?? "",
                    ext: args["file_extension"] as? String ?? "swift"
                )
            default:
                return "Unknown tool: \(name)"
            }
        }
    }

    // MARK: - WITH arm: ContextVault tools

    func runWithContextVault(
        task:     String,
        tools mcpTools: MCPTools,
        project:  Project,
        maxTurns: Int = 8
    ) async throws -> AgentRunResult {
        let cvTools = [
            openAITool(
                name: "get_project_context",
                description: "CALL THIS FIRST. Returns project notes and a code index summary. Costs ~200 tokens instead of thousands for file reads.",
                parameters: ["path": ["type": "string", "description": "Your working directory"]]
            ),
            openAITool(
                name: "search_code",
                description: "BM25 semantic search over the indexed codebase. Returns matching function bodies only — 10-20× cheaper than read_file because it skips irrelevant code.",
                parameters: [
                    "project": ["type": "string", "description": "Project slug (from get_project_context)"],
                    "query":   ["type": "string", "description": "Natural language search query"],
                    "topK":    ["type": "integer", "description": "Max results (default 5)"],
                ]
            ),
            openAITool(
                name: "compress",
                description: "Compress any large content before reading it. 40-70% size reduction.",
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
            mcpTools.handle(name: name, arguments: args).content
        }
    }

    // MARK: - Agentic loop

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

            var assistantMsg: [String: Any] = ["role": "assistant"]
            if !response.textContent.isEmpty { assistantMsg["content"] = response.textContent }
            assistantMsg["tool_calls"] = response.toolCalls.map { tc -> [String: Any] in
                ["id": tc.id, "type": "function",
                 "function": ["name": tc.name, "arguments": tc.rawArguments]]
            }
            messages.append(assistantMsg)

            for tc in response.toolCalls {
                toolCalls.append(tc.name)
                let args   = parseJSON(tc.rawArguments)
                let result = executor(tc.name, args)
                testLog.toolCall(name: tc.name, preview: tc.rawArguments)
                testLog.toolResult(chars: result.count, preview: String(result.prefix(80)))
                messages.append(["role": "tool", "tool_call_id": tc.id, "content": result])
            }
        }

        return AgentRunResult(turns: turns, toolCalls: toolCalls,
                              promptTokens: totalPrompt, completionTokens: totalComp,
                              finalAnswer: finalAnswer)
    }

    // MARK: - Filesystem tool implementations

    private static func listDirectory(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
        ) else { return "Error: cannot list '\(path)'" }

        let lines = entries.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { e -> String in
            let isDir = (try? e.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDir ? "\(e.lastPathComponent)/" : e.lastPathComponent
        }
        return "Contents of \(path):\n" + lines.joined(separator: "\n")
    }

    private static func readFile(_ path: String) -> String {
        guard !path.isEmpty else { return "Error: empty path" }
        guard let content = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) else {
            return "Error: cannot read '\(path)'"
        }
        return "// \(path)\n\(content)"
    }

    private static func searchFiles(in dirPath: String, pattern: String, ext: String) -> String {
        guard !pattern.isEmpty else { return "Error: empty pattern" }
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: dirPath), includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return "Error: cannot enumerate '\(dirPath)'" }

        var results: [String] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == ext,
                  let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let rel = url.path.replacingOccurrences(of: dirPath + "/", with: "")
            for (i, line) in content.components(separatedBy: "\n").enumerated() {
                if line.range(of: pattern, options: .caseInsensitive) != nil {
                    results.append("\(rel):\(i + 1):\t\(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        if results.isEmpty { return "No matches for '\(pattern)'" }
        let out = results.prefix(60).joined(separator: "\n")
        return results.count > 60 ? out + "\n[\(results.count - 60) more matches omitted]" : out
    }

    // MARK: - HTTP

    private struct ChatResponse {
        let textContent: String; let toolCalls: [ToolCall]
        let promptTokens: Int;   let completionTokens: Int
    }
    private struct ToolCall { let id: String; let name: String; let rawArguments: String }

    private func callChatAPI(messages: [[String: Any]], tools: [[String: Any]]) async throws -> ChatResponse {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json",  forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = ["model": model, "messages": messages]
        if !tools.isEmpty { body["tools"] = tools }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw OpenAIError.apiError(String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenAIError.invalidResponse
        }

        let usage    = json["usage"]   as? [String: Any] ?? [:]
        let message  = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] ?? [:]
        let rawCalls = message["tool_calls"] as? [[String: Any]] ?? []

        let promptTok = usage["prompt_tokens"]     as? Int ?? 0
        let compTok   = usage["completion_tokens"] as? Int ?? 0
        testLog.apiCall(model: model, promptTok: promptTok, compTok: compTok)

        return ChatResponse(
            textContent:      message["content"]          as? String ?? "",
            toolCalls:        rawCalls.compactMap { tc -> ToolCall? in
                guard let id   = tc["id"]       as? String,
                      let fn   = tc["function"] as? [String: Any],
                      let name = fn["name"]     as? String,
                      let args = fn["arguments"] as? String else { return nil }
                return ToolCall(id: id, name: name, rawArguments: args)
            },
            promptTokens:     promptTok,
            completionTokens: compTok
        )
    }

    // MARK: - Helpers

    private func openAITool(name: String, description: String, parameters: [String: Any]) -> [String: Any] {
        ["type": "function", "function": [
            "name": name, "description": description,
            "parameters": ["type": "object", "properties": parameters] as [String: Any],
        ] as [String: Any]]
    }

    private func parseJSON(_ raw: String) -> [String: Any] {
        guard let d = raw.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }
}

enum OpenAIError: Error {
    case apiError(String)
    case invalidResponse
}
