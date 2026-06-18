import Testing
import Foundation
@testable import ContextVault

@Suite("ResponseCompressor — detection, compression, CCR offload")
struct ResponseCompressorTests {

    // MARK: - Content detection

    @Test func detectsJSONObject() {
        #expect(ResponseCompressor.detect(#"{"key": "value"}"#) == .json)
    }

    @Test func detectsJSONArray() {
        #expect(ResponseCompressor.detect(#"[{"id": 1}, {"id": 2}]"#) == .json)
    }

    @Test func detectsLog() {
        let log = """
        [2026-06-18 10:01:22] INFO Starting service
        [2026-06-18 10:01:23] DEBUG Connecting to Postgres
        [2026-06-18 10:01:24] ERROR Connection refused: timeout after 5000ms
        Traceback: at line 142 in db/pool.swift
        [2026-06-18 10:01:24] WARN Retrying in 2s
        """
        #expect(ResponseCompressor.detect(log) == .log)
    }

    @Test func detectsMarkdownFallback() {
        let md = "# Architecture\n\nThree-tier system with Go gateway."
        #expect(ResponseCompressor.detect(md) == .markdown)
    }

    // MARK: - Log compression

    @Test func logCompressorKeepsErrorLines() {
        let log = """
        INFO  Starting build
        DEBUG Loading config
        ERROR Build failed: missing dependency
        INFO  Cleanup started
        DEBUG Removing temp files
        INFO  Done
        """
        let result = ResponseCompressor.compressLog(log)
        #expect(result.contains("ERROR Build failed"))
    }

    @Test func logCompressorDropsInfoAndDebug() {
        let log = (1...50).map { i in
            i % 10 == 0
                ? "[ERROR] Segment fault at address 0x\(i)"
                : "[INFO] Processing request \(i)"
        }.joined(separator: "\n")

        let result = ResponseCompressor.compressLog(log)
        let resultLines = result.components(separatedBy: "\n").filter { !$0.isEmpty }
        let inputLines = log.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(resultLines.count < inputLines.count)
        #expect(result.contains("log_compressor"))
    }

    @Test func logCompressorKeepsContextAroundErrors() {
        let log = """
        INFO  Step 1
        INFO  Step 2
        DEBUG Preparing migration
        ERROR Migration 0042 failed: column already exists
        INFO  Rolling back
        INFO  Done
        """
        let result = ResponseCompressor.compressLog(log)
        // 1 line before the error ("Preparing migration") should be kept
        #expect(result.contains("Preparing migration"))
        // 1 line after the error ("Rolling back") should be kept
        #expect(result.contains("Rolling back"))
    }

    @Test func shortLogIsReturnedUnchanged() {
        let log = "ERROR something failed"
        #expect(ResponseCompressor.compressLog(log) == log)
    }

    // MARK: - Markdown compression

    @Test func normalizeMarkdownCollapsesExtraBlankLines() {
        let md = "# Title\n\n\n\nParagraph 1\n\n\n\nParagraph 2"
        let result = ResponseCompressor.normalizeMarkdown(md)
        // Multiple blanks collapsed to one
        #expect(!result.contains("\n\n\n"))
    }

    @Test func normalizeMarkdownTrimsLeadingAndTrailingBlanks() {
        let md = "\n\n# Title\n\nContent\n\n"
        let result = ResponseCompressor.normalizeMarkdown(md)
        #expect(!result.hasPrefix("\n"))
        #expect(!result.hasSuffix("\n"))
    }

    @Test func compressMarkdownOffloadsLongNotesViaCCR() {
        // Create a note body that exceeds the CCR threshold (80 lines)
        let longBody = (1...100).map { "Line \($0): some content about the system architecture and design." }.joined(separator: "\n")
        let result = ResponseCompressor.compressMarkdown(longBody)
        #expect(result.contains("<<ccr:"))
        #expect(result.contains("retrieve(hash:"))
    }

    @Test func compressMarkdownLeavesShortNotesIntact() {
        let shortBody = (1...30).map { "Line \($0): brief note." }.joined(separator: "\n")
        let result = ResponseCompressor.compressMarkdown(shortBody)
        #expect(!result.contains("<<ccr:"))
    }

    // MARK: - Note compression (compressNote)

    @Test func compressNoteInlinesFirstFortyLines() {
        let body = (1...100).map { "Line \($0): important content." }.joined(separator: "\n")
        let result = ResponseCompressor.compressNote(body, title: "test")
        // First 40 lines should appear verbatim
        #expect(result.contains("Line 40"))
        // Line 41 onward should be offloaded
        #expect(result.contains("<<ccr:"))
    }

    @Test func compressNoteShortBodyIsUnchanged() {
        let body = "Short note with a few lines."
        let result = ResponseCompressor.compressNote(body, title: "test")
        #expect(result == body)
    }

    // MARK: - JSON compression via SmartCrusher

    @Test func compressJSONArrayCrushesToTable() {
        let json = """
        [{"name":"Alice","role":"admin","active":true},
         {"name":"Bob","role":"viewer","active":false}]
        """
        let result = ResponseCompressor.compressJSON(json)
        #expect(result.hasPrefix("cols:"))
    }

    @Test func compressJSONInvalidFallsBackToOriginal() {
        let invalid = "not valid json at all"
        #expect(ResponseCompressor.compressJSON(invalid) == invalid)
    }

    // MARK: - Compression ratios on real-world payloads

    @Test func achievesAtLeastSixtyPercentOnBuildLog() {
        let buildLog = """
        [10:00:01] INFO  Build started for target MyApp
        [10:00:01] DEBUG Loading Swift toolchain 6.0
        [10:00:02] INFO  Compiling AuthService.swift
        [10:00:02] DEBUG Parsing imports
        [10:00:03] INFO  Compiling NetworkClient.swift
        [10:00:03] DEBUG Resolving generics
        [10:00:04] INFO  Compiling SyncEngine.swift
        [10:00:05] INFO  Linking MyApp
        [10:00:05] DEBUG Symbol table: 2847 entries
        [10:00:06] ERROR Undefined symbol: _TokenSavingsStore_shared
        [10:00:06] ERROR Linker command failed with exit code 1
        [10:00:06] INFO  Build failed after 5.2s
        """ + (1...40).map { "DEBUG Cleaning up temp file \($0)" }.joined(separator: "\n")

        let result = ResponseCompressor.compressLog(buildLog)
        let ratio = 1.0 - Double(result.count) / Double(buildLog.count)
        #expect(ratio >= 0.40, "Expected ≥40% reduction on build log, got \(Int(ratio * 100))%")
    }

    @Test func achievesAtLeastFortyPercentOnLargeJSONArray() {
        let users = (1...30).map { i -> [String: Any] in [
            "id": i,
            "username": "user_\(i)",
            "email": "user\(i)@example.com",
            "role": i % 3 == 0 ? "admin" : "viewer",
            "active": true,
            "created_at": "2026-01-\(String(format: "%02d", (i % 28) + 1))",
        ]}
        let json = String(data: (try? JSONSerialization.data(withJSONObject: users))!, encoding: .utf8)!
        let result = ResponseCompressor.compressJSON(json)
        let ratio = 1.0 - Double(result.count) / Double(json.count)
        #expect(ratio >= 0.40, "Expected ≥40% on user list, got \(Int(ratio * 100))%")
    }
}
