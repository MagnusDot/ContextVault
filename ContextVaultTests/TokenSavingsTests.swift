import Testing
import Foundation
@testable import ContextVault

// Tests for token savings tracking and the core economic claim:
// ContextVault costs significantly fewer tokens than reading source files directly.
@Suite("Token savings — calculation and economic claims")
struct TokenSavingsTests {

    // MARK: - TokenSavingsStore

    @Test func recordAccumulatesTotalSaved() {
        let slug = "test-savings-\(UUID().uuidString.prefix(8))"
        let store = TokenSavingsStore.shared

        store.record(slug: slug, savedTokens: 1200)
        store.record(slug: slug, savedTokens: 800)
        store.record(slug: slug, savedTokens: 2500)

        let s = store.savings(slug: slug)
        #expect(s.totalSaved == 4500)
        #expect(s.callCount == 3)
    }

    @Test func recordIgnoresNegativeSavings() {
        let slug = "test-savings-\(UUID().uuidString.prefix(8))"
        let store = TokenSavingsStore.shared

        store.record(slug: slug, savedTokens: 1000)
        store.record(slug: slug, savedTokens: -500)  // impossible case — should be ignored

        #expect(store.savings(slug: slug).totalSaved == 1000)
        #expect(store.savings(slug: slug).callCount == 2)
    }

    @Test func savingsAreSeparatePerSlug() {
        let slug1 = "proj-a-\(UUID().uuidString.prefix(8))"
        let slug2 = "proj-b-\(UUID().uuidString.prefix(8))"
        let store = TokenSavingsStore.shared

        store.record(slug: slug1, savedTokens: 5000)
        store.record(slug: slug2, savedTokens: 1000)

        #expect(store.savings(slug: slug1).totalSaved == 5000)
        #expect(store.savings(slug: slug2).totalSaved == 1000)
    }

    @Test func freshSlugStartsAtZero() {
        let slug = "fresh-\(UUID().uuidString)"
        let s = TokenSavingsStore.shared.savings(slug: slug)
        #expect(s.totalSaved == 0)
        #expect(s.callCount == 0)
    }

    // MARK: - Token cost estimation

    // Token estimation: 1 token ≈ 4 characters (OpenAI / Anthropic approximation)
    private func estimateTokens(_ text: String) -> Int { text.count / 4 }
    private func estimateTokens(chars: Int) -> Int { chars / 4 }

    // MARK: - Economic claim: get_project_context vs full file reads

    @Test func contextNotesCostFarFewerTokensThanReadingFiles() throws {
        // "Old way": agent reads all source files to understand the project
        let oldWayCost = SeedData.fullReadTokenCost

        // "ContextVault way": get_project_context returns compact notes
        // We measure the actual size of the seed notes
        let noteTokens = SeedData.allNotes.reduce(0) {
            $0 + estimateTokens($1.body) + estimateTokens($1.title) + 20  // 20 tok overhead per note
        }

        let savingsRatio = Double(oldWayCost) / Double(noteTokens)

        #expect(oldWayCost > 10_000,
            "Fake codebase should cost at least 10k tokens to read fully (got \(oldWayCost))")
        #expect(noteTokens < 1_000,
            "Notes should cost under 1k tokens (got \(noteTokens))")
        #expect(savingsRatio >= 10.0,
            "Expected at least 10× savings ratio, got \(String(format: "%.1f", savingsRatio))×")
    }

    @Test func compressionReducesResponseSizeByAtLeastFortyPercent() {
        // Simulate a typical agent receiving a JSON API response
        let rawJSON = """
        [{"id":1,"title":"Fix auth","status":"open","priority":"high","author":"alice","comments":3,"labels":["bug","auth"]},
         {"id":2,"title":"Add dark mode","status":"merged","priority":"low","author":"bob","comments":7,"labels":["ui"]},
         {"id":3,"title":"Update tests","status":"open","priority":"medium","author":"carol","comments":1,"labels":["tests"]},
         {"id":4,"title":"Refactor sync","status":"open","priority":"high","author":"dave","comments":4,"labels":["backend"]},
         {"id":5,"title":"Fix memory leak","status":"closed","priority":"critical","author":"alice","comments":9,"labels":["bug"]}]
        """
        let compressed = ResponseCompressor.compress(rawJSON)
        let ratio = 1.0 - Double(compressed.count) / Double(rawJSON.count)
        #expect(ratio >= 0.40,
            "compress() should reduce JSON by ≥40%, got \(Int(ratio * 100))%")
    }

    // MARK: - End-to-end savings simulation

    @Test func endToEndSessionSavingsExceedFiveX() throws {
        // Full agent session simulation comparing old vs ContextVault approach.
        //
        // OLD WAY (without ContextVault):
        //   • Agent reads 15 source files (full content) to understand the codebase
        //   • Agent grep-searches for relevant functions → reads 3 more files
        //   • Agent receives a raw JSON tool output (GitHub PR list, 25 items)
        //   • Agent re-reads the context file from scratch mid-session
        let oldWayFilesTokens = SeedData.fullReadTokenCost          // 15 files read in full
        let oldWayGrepTokens  = 3 * 1500                            // 3 more files after grep
        let rawPRList = (1...25).map { i -> [String: Any] in
            ["number": i, "title": "PR \(i)", "state": "open",
             "author": "dev\(i % 4)", "comments": i, "draft": false,
             "created_at": "2026-06-\(String(format: "%02d", (i % 28) + 1))T10:00:00Z"]
        }
        let rawJSON = String(data: (try? JSONSerialization.data(withJSONObject: rawPRList))!, encoding: .utf8)!
        let oldWayJSONTokens  = estimateTokens(rawJSON)             // raw PR list
        let oldWayRereadTokens = 800                                 // re-reading context mid-session
        let totalOldWay = oldWayFilesTokens + oldWayGrepTokens + oldWayJSONTokens + oldWayRereadTokens

        // CONTEXTVAULT WAY:
        //   • get_project_context: reads 3 compact notes
        //   • 3 × search_code calls: returns matching function bodies (avg 200 chars each)
        //   • compress() on the JSON PR list
        //   • 2nd get_project_context call → KV-cache hit (effectively 0 tokens)
        let cvContextTokens = SeedData.allNotes.reduce(0) { $0 + estimateTokens($1.body) } + 50
        let cvSearchTokens  = 3 * (200 / 4)   // 3 searches × 200 chars of matching code
        let compressedJSON  = ResponseCompressor.compress(rawJSON)
        let cvJSONTokens    = estimateTokens(compressedJSON)
        let cvCacheHitTokens = 0               // 2nd get_project_context is a KV-cache hit
        let totalCV = cvContextTokens + cvSearchTokens + cvJSONTokens + cvCacheHitTokens

        let savingsRatio = Double(totalOldWay) / Double(totalCV)
        let savingsTokens = totalOldWay - totalCV
        let savingsPct = Int((1.0 - Double(totalCV) / Double(totalOldWay)) * 100)

        print("""
        ── Session cost comparison ──────────────────────────
        WITHOUT ContextVault: \(totalOldWay) tokens
          • Read 15 source files:         \(oldWayFilesTokens) tok
          • grep + read 3 more files:     \(oldWayGrepTokens) tok
          • Raw JSON PR list (\(rawPRList.count) items):  \(oldWayJSONTokens) tok
          • Re-read context mid-session:  \(oldWayRereadTokens) tok

        WITH ContextVault:    \(totalCV) tokens
          • get_project_context (3 notes): \(cvContextTokens) tok
          • 3× search_code results:        \(cvSearchTokens) tok
          • compress(JSON PR list):        \(cvJSONTokens) tok
          • 2nd get_project_context:       \(cvCacheHitTokens) tok (KV-cache hit)

        Savings: \(savingsTokens) tokens — \(savingsPct)% — \(String(format: "%.1f", savingsRatio))× fewer
        ─────────────────────────────────────────────────────
        """)

        #expect(savingsRatio >= 5.0,
            "Expected at least 5× savings, got \(String(format: "%.1f", savingsRatio))×")
        #expect(savingsPct >= 75,
            "Expected at least 75% token reduction, got \(savingsPct)%")
    }

    // MARK: - Monthly cost projection

    @Test func monthlyProjectionShowsSignificantCostReduction() throws {
        // Based on the end-to-end session above, project to 30 days at 5 sessions/day.
        // Sonnet pricing: $3 / 1M input tokens.
        let sessionsPerDay = 5
        let daysPerMonth = 30
        let totalSessions = sessionsPerDay * daysPerMonth

        // Approximate per-session costs from the scenario above
        let oldWayPerSession = SeedData.fullReadTokenCost + 3 * 1500 + 1000 + 800
        let cvPerSession     = SeedData.allNotes.reduce(0) { $0 + $1.body.count / 4 } + 150 + 300

        let oldWayMonthly = oldWayPerSession * totalSessions
        let cvMonthly     = cvPerSession * totalSessions

        let costPerToken = 3.0 / 1_000_000  // $3 / 1M tokens
        let oldWayCost   = Double(oldWayMonthly) * costPerToken
        let cvCost       = Double(cvMonthly)     * costPerToken
        let monthlySaved = oldWayCost - cvCost

        print("""
        ── Monthly projection (30 days, 5 sessions/day) ────
        WITHOUT ContextVault: \(oldWayMonthly / 1000)k tokens — $\(String(format: "%.2f", oldWayCost))
        WITH ContextVault:    \(cvMonthly / 1000)k tokens — $\(String(format: "%.2f", cvCost))
        Monthly savings:      $\(String(format: "%.2f", monthlySaved)) per developer
        ─────────────────────────────────────────────────────
        """)

        #expect(monthlySaved > 1.0, "Monthly savings should exceed $1 per developer")
        #expect(oldWayMonthly > cvMonthly * 3, "Old way should cost at least 3× more monthly")
    }
}
