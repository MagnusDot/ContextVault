import Testing
import Foundation
@testable import ContextVault

@Suite("SmartCrusher — JSON → columnar table")
struct SmartCrusherTests {

    // MARK: - Array crushing

    @Test func crushesHomogeneousArrayToColumnarTable() {
        let arr: [[String: Any]] = [
            ["id": "PR-1", "title": "Fix auth bug",  "status": "open",   "author": "alice"],
            ["id": "PR-2", "title": "Add dark mode", "status": "merged", "author": "bob"],
            ["id": "PR-3", "title": "Update deps",   "status": "open",   "author": "carol"],
        ]
        let result = SmartCrusher.crush(arr)
        #expect(result != nil)
        #expect(result!.hasPrefix("cols:"))
        #expect(result!.contains("author | id | status | title"))  // sorted columns
        #expect(result!.contains("alice"))
        #expect(result!.contains("Fix auth bug"))
        // Columnar format is much more compact than JSON
        let jsonSize = (try? JSONSerialization.data(withJSONObject: arr))?.count ?? 0
        #expect(result!.count < jsonSize)
    }

    @Test func inlinesUpToEightRows() {
        let arr = (1...8).map { i -> [String: Any] in ["id": i, "name": "item-\(i)"] }
        let result = SmartCrusher.crush(arr)!
        // All 8 rows should be inline — no CCR marker needed
        #expect(!result.contains("more rows"))
    }

    @Test func offloadsRowsBeyondLimitViaCCR() {
        let arr = (1...20).map { i -> [String: Any] in ["id": i, "name": "item-\(i)"] }
        let result = SmartCrusher.crush(arr)!
        // Rows 9–20 must be offloaded
        #expect(result.contains("more rows"))
        #expect(result.contains("retrieve(hash:"))
    }

    @Test func offloadedRowsAreRetrievableFromCCRStore() {
        let arr = (1...15).map { i -> [String: Any] in ["id": i, "value": "v\(i)"] }
        let result = SmartCrusher.crush(arr)!

        // Extract the hash from "[ N more rows — retrieve(hash:"<hash>")]"
        let pattern = #/retrieve\(hash:"([^"]+)"\)/#
        if let match = result.firstMatch(of: pattern) {
            let hash = String(match.output.1)
            let retrieved = CCRStore.shared.get(hash)
            #expect(retrieved != nil)
            // Should contain rows 9–15 as JSON
            #expect(retrieved!.contains("\"id\""))
        } else {
            Issue.record("No CCR hash found in result: \(result)")
        }
    }

    @Test func crushesObjectWithFourOrMoreKeys() {
        let obj: [String: Any] = [
            "name": "ContextVault",
            "version": "1.0",
            "platform": "macOS",
            "protocol": "MCP",
            "port": 9876,
        ]
        let result = SmartCrusher.crush(obj)
        #expect(result != nil)
        // key: value per line
        #expect(result!.contains("name: ContextVault"))
        #expect(result!.contains("port: 9876"))
    }

    @Test func returnsNilForSmallArraysUnderTwoItems() {
        let arr: [[String: Any]] = [["id": 1]]
        #expect(SmartCrusher.crush(arr) == nil)
    }

    @Test func returnsNilForObjectWithFewerThanFourKeys() {
        let obj: [String: Any] = ["a": 1, "b": 2]
        #expect(SmartCrusher.crush(obj) == nil)
    }

    // MARK: - Cell formatting

    @Test func formatCellHandlesNil() {
        #expect(SmartCrusher.formatCell(nil) == "∅")
    }

    @Test func formatCellHandlesNSNull() {
        #expect(SmartCrusher.formatCell(NSNull()) == "∅")
    }

    @Test func formatCellHandlesBool() {
        #expect(SmartCrusher.formatCell(true)  == "✓")
        #expect(SmartCrusher.formatCell(false) == "✗")
    }

    @Test func formatCellTruncatesLongStrings() {
        let long = String(repeating: "x", count: 60)
        let result = SmartCrusher.formatCell(long)
        #expect(result.count <= 40)
        #expect(result.hasSuffix("…"))
    }

    @Test func formatCellHandlesNestedObject() {
        let obj: [String: Any] = ["a": 1, "b": 2]
        #expect(SmartCrusher.formatCell(obj) == "{…2keys}")
    }

    @Test func formatCellHandlesNestedArray() {
        let arr: [Any] = [1, 2, 3]
        #expect(SmartCrusher.formatCell(arr) == "[…3]")
    }

    @Test func formatCellHandlesEmptyString() {
        #expect(SmartCrusher.formatCell("") == "\"\"")
        #expect(SmartCrusher.formatCell("   ") == "\"\"")
    }

    // MARK: - Compression ratio

    @Test func achievesAtLeastFortyPercentReductionOnTypicalAPIResponse() {
        // Simulate a typical GitHub PR list response
        let modules = ["auth", "sync", "network", "ui"]
        let authors = ["alice", "bob", "carol", "dave"]
        let prs: [[String: Any]] = (1...25).map { i in
            let module = modules[i % modules.count]
            let author = authors[i % authors.count]
            let day    = String(format: "%02d", (i % 28) + 1)
            return [
                "number":     i,
                "title":      "Fix issue #\(i) in module \(module)",
                "state":      i % 3 == 0 ? "merged" : "open",
                "author":     author,
                "created_at": "2026-06-\(day)T10:00:00Z",
                "comments":   i * 2,
                "draft":      i % 5 == 0,
            ]
        }

        let jsonData = (try? JSONSerialization.data(withJSONObject: prs))!
        let jsonStr = String(data: jsonData, encoding: .utf8)!
        let crushed = SmartCrusher.crush(prs)!

        let reductionPct = 1.0 - Double(crushed.count) / Double(jsonStr.count)
        #expect(reductionPct >= 0.40, "Expected ≥40% reduction, got \(Int(reductionPct * 100))%")
    }
}
