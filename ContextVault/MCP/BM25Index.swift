import Foundation

// Parameters: k1=1.5 (TF saturation), b=0.75 (length normalisation).
struct BM25Index {

    private let chunks: [CodeChunk]
    private let k1: Double = 1.5
    private let b:  Double = 0.75

    // inverted index: token → [(chunkIndex, termFrequency)]
    private let invertedIndex: [String: [(Int, Double)]]
    private let docLengths: [Double]
    private let avgDocLen: Double

    // Lookup by file:startLine
    private let byId: [String: CodeChunk]

    // Reference graph (aider-style): how many OTHER chunks mention each defined symbol.
    // A symbol called from 20 places is more important context than a one-off helper.
    // Built purely from indexed chunk bodies — no tree-sitter, no external deps.
    private let symbolRefs: [String: Int]

    init(chunks: [CodeChunk]) {
        self.chunks = chunks

        var inv: [String: [(Int, Double)]] = [:]
        var lengths: [Double] = []
        var idMap: [String: CodeChunk] = [:]
        var bodyTokenSets: [Set<String>] = []

        for (idx, chunk) in chunks.enumerated() {
            let tokens = BM25Index.tokenize(chunk.body)
            let tokenSet = Dictionary(grouping: tokens, by: { $0 }).mapValues { Double($0.count) }
            lengths.append(Double(tokens.count))
            for (token, tf) in tokenSet {
                inv[token, default: []].append((idx, tf))
            }
            idMap[chunk.id] = chunk
            bodyTokenSets.append(Set(tokens))
        }

        self.invertedIndex = inv
        self.docLengths = lengths
        self.avgDocLen = lengths.isEmpty ? 1 : lengths.reduce(0, +) / Double(lengths.count)
        self.byId = idMap

        // Reference counts: for each chunk, every defined symbol it mentions (other than its
        // own name) scores one reference. The tokenizer keeps the full lowercased symbol word,
        // so "MCPTools" in a body matches the chunk named "MCPTools".
        let defined = Set(chunks.map { $0.name.lowercased() }).subtracting(["unknown", ""])
        var refs: [String: Int] = [:]
        for (idx, chunk) in chunks.enumerated() {
            let selfName = chunk.name.lowercased()
            for sym in bodyTokenSets[idx].intersection(defined) where sym != selfName {
                refs[sym, default: 0] += 1
            }
        }
        self.symbolRefs = refs
    }

    // How many distinct chunks reference this symbol elsewhere in the codebase.
    func referenceCount(_ name: String) -> Int {
        symbolRefs[name.lowercased()] ?? 0
    }

    // MARK: - Search

    func search(query: String, topK: Int = 8) -> [ScoredChunk] {
        let qTokens = Set(BM25Index.tokenize(query))
        guard !qTokens.isEmpty else { return [] }

        var scores: [Double] = Array(repeating: 0, count: chunks.count)
        let N = Double(chunks.count)

        for token in qTokens {
            guard let postings = invertedIndex[token] else { continue }
            let df = Double(postings.count)
            let idf = log((N - df + 0.5) / (df + 0.5) + 1)
            for (idx, tf) in postings {
                let dl  = docLengths[idx]
                let norm = k1 * (1 - b + b * dl / avgDocLen)
                scores[idx] += idf * (tf * (k1 + 1)) / (tf + norm)
            }
        }

        // Centrality boost (aider-style): nudge well-referenced symbols up when relevance ties.
        // Gentle by design — log-scaled and capped so it never overrides a clearly better match.
        return scores
            .enumerated()
            .filter { $0.element > 0 }
            .map { (offset, score) -> (Int, Double) in
                let refs = referenceCount(chunks[offset].name)
                let boost = 1 + 0.08 * log2(Double(min(refs, 32) + 1))
                return (offset, score * boost)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(topK)
            .map { ScoredChunk(chunk: chunks[$0.0], score: $0.1) }
    }

    func chunk(file: String, startLine: Int) -> CodeChunk? {
        byId["\(file):\(startLine)"]
    }

    var count: Int { chunks.count }
    var allChunks: [CodeChunk] { chunks }

    // Score = typeWeight × log(lineCount + 1) — large structs/classes rank above tiny helpers.
    func topChunks(limit: Int) -> [CodeChunk] {
        let w: [CodeChunk.ChunkType: Double] = [
            .class_: 5, .struct_: 4, .extension_: 3, .enum_: 2, .function: 1
        ]
        return Array(
            chunks.sorted {
                (w[$0.type] ?? 1) * log(Double($0.lineCount) + 1) >
                (w[$1.type] ?? 1) * log(Double($1.lineCount) + 1)
            }.prefix(limit)
        )
    }

    // MARK: - Tokenizer

    // Splits on non-alnum boundaries + expands camelCase/snake_case.
    static func tokenize(_ text: String) -> [String] {
        let raw = text.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .flatMap { expandCamel($0) }
            .map { $0.lowercased() }
            .filter { $0.count >= 2 }

        // 2. Remove pure-noise code tokens
        let noise: Set<String> = ["let", "var", "return", "self", "super", "true", "false",
                                   "nil", "if", "else", "for", "in", "while", "do", "try",
                                   "catch", "guard", "switch", "case", "break", "continue",
                                   "import", "from", "const", "type", "async", "await", "new"]
        return raw.filter { !noise.contains($0) }
    }

    // "fetchProjectContext" → ["fetch", "project", "context"]
    private static func expandCamel(_ word: String) -> [String] {
        guard !word.isEmpty else { return [] }
        var parts: [String] = []
        var current = ""
        for ch in word {
            if ch.isUppercase && !current.isEmpty {
                parts.append(current)
                current = String(ch.lowercased())
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { parts.append(current) }
        // Also keep the full word for exact-match queries
        if parts.count > 1 { parts.append(word.lowercased()) }
        return parts
    }
}
