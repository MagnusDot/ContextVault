import os
import Foundation

// Unified logger for all ContextVaultTests.
// Output appears in real-time in Xcode's debug console (bottom panel) and in Console.app.
// Filter in Console.app: subsystem = "cv.tests"
//
// Usage:  testLog.info("message")
//         testLog.section("RAG init")
//         testLog.result("search_code", tokens: 240, correct: true)
let testLog = TestLogger()

struct TestLogger {
    private let log = Logger(subsystem: "cv.tests", category: "bench")

    // MARK: - Levels

    func debug(_ msg: String) {
        log.debug("🔍 \(msg, privacy: .public)")
    }

    func info(_ msg: String) {
        log.info("ℹ️  \(msg, privacy: .public)")
    }

    func ok(_ msg: String) {
        log.info("✅ \(msg, privacy: .public)")
    }

    func warn(_ msg: String) {
        log.warning("⚠️  \(msg, privacy: .public)")
    }

    func error(_ msg: String) {
        log.error("❌ \(msg, privacy: .public)")
    }

    // MARK: - Structured events

    func section(_ name: String) {
        log.info("── \(name, privacy: .public) ─────────────────────────────────")
    }

    func setup(files: Int, chunks: Int, slug: String) {
        log.info("📦 Setup: \(files, privacy: .public) files → \(chunks, privacy: .public) chunks  slug=\(slug, privacy: .public)")
    }

    func search(query: String, hits: Int, topScore: Double) {
        log.info("🔎 search(\"\(query, privacy: .public)\") → \(hits, privacy: .public) hits  top=\(String(format: "%.2f", topScore), privacy: .public)")
    }

    func toolCall(name: String, preview: String) {
        log.debug("🔧 \(name, privacy: .public)  \(preview.prefix(80), privacy: .public)")
    }

    func toolResult(chars: Int, preview: String) {
        log.debug("   ↳ [\(chars, privacy: .public)c]  \(preview.prefix(80), privacy: .public)")
    }

    func run(n: Int, total: Int, arm: String, task: String) {
        log.info("[\(n, privacy: .public)/\(total, privacy: .public)] \(arm, privacy: .public)  \(task, privacy: .public)")
    }

    func tokens(without: Int, with: Int) {
        let ratio  = Double(without) / Double(max(1, with))
        let saving = Int(Double(without - with) / Double(max(1, without)) * 100)
        log.info("💰 WITHOUT \(without, privacy: .public) tok  WITH \(with, privacy: .public) tok  → \(saving, privacy: .public)%  (\(String(format: "%.1f", ratio), privacy: .public)×)")
    }

    func correct(_ pass: Bool, task: String) {
        if pass {
            log.info("✅ correct  \(task, privacy: .public)")
        } else {
            log.warning("✗  wrong    \(task, privacy: .public)")
        }
    }

    func apiCall(model: String, promptTok: Int, compTok: Int) {
        log.debug("🤖 \(model, privacy: .public)  prompt=\(promptTok, privacy: .public)  completion=\(compTok, privacy: .public)")
    }

    func skip(_ reason: String) {
        log.info("⏭  \(reason, privacy: .public)")
    }
}
