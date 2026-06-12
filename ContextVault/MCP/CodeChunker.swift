import Foundation

// Parses source files into function/class/struct-level chunks for RAG indexing.
// Uses brace counting for C-like languages, indentation for Python.
enum CodeChunker {

    static let maxChunkLines = 200
    static let minChunkLines = 3

    struct ProjectResult {
        let chunks: [CodeChunk]
        let fileCount: Int
    }

    // Scan a project directory and return all code chunks.
    static func chunkProject(
        at root: String,
        extensions: [String] = ["swift","ts","tsx","js","jsx","py","go","rs","kt"],
        onProgress: ((Double, String) -> Void)? = nil
    ) -> ProjectResult {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return .init(chunks: [], fileCount: 0) }

        var files: [URL] = []
        let extSet = Set(extensions)
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            if extSet.contains(ext) { files.append(url) }
        }

        var allChunks: [CodeChunk] = []
        for (i, url) in files.enumerated() {
            let relative = url.path.hasPrefix(root)
                ? String(url.path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                : url.path
            let chunks = chunkFile(at: url.path, relativePath: relative)
            allChunks.append(contentsOf: chunks)
            onProgress?(Double(i + 1) / Double(files.count), "Indexing \(relative)…")
        }

        return .init(chunks: allChunks, fileCount: files.count)
    }

    // Parse a single file into chunks.
    static func chunkFile(at path: String, relativePath: String) -> [CodeChunk] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let lines = content.components(separatedBy: "\n")
        switch ext {
        case "swift", "kt":          return extractBraceChunks(lines, file: relativePath, lang: .swift)
        case "ts", "tsx", "js", "jsx": return extractBraceChunks(lines, file: relativePath, lang: .typescript)
        case "go":                   return extractBraceChunks(lines, file: relativePath, lang: .go)
        case "rs":                   return extractBraceChunks(lines, file: relativePath, lang: .rust)
        case "py":                   return extractPythonChunks(lines, file: relativePath)
        default:                     return []
        }
    }

    // MARK: - Brace-based extraction (Swift / TS / Go / Rust)

    private enum Lang {
        case swift, typescript, go, rust

        // (regex pattern, chunk type) pairs
        var specs: [(String, CodeChunk.ChunkType)] {
            switch self {
            case .swift:
                return [
                    (#"^\s*(public|private|internal|fileprivate|open|static|class|final|override|async|nonisolated|@\w+(\([^)]*\))?\s+)*func\s+\w+"#, .function),
                    (#"^\s*(public|private|internal|open|final|@\w+(\([^)]*\))?\s+)*class\s+\w+"#, .class_),
                    (#"^\s*(public|private|internal|@\w+(\([^)]*\))?\s+)*struct\s+\w+"#, .struct_),
                    (#"^\s*(public|private|internal|@\w+(\([^)]*\))?\s+)*enum\s+\w+"#, .enum_),
                    (#"^\s*(public|private|internal|@\w+(\([^)]*\))?\s+)*extension\s+\w+"#, .extension_),
                ]
            case .typescript:
                return [
                    (#"^\s*(export\s+)?(default\s+)?(async\s+)?function\s+\w+"#, .function),
                    (#"^\s*(export\s+)?(abstract\s+)?class\s+\w+"#, .class_),
                    (#"^\s*(export\s+)?interface\s+\w+"#, .struct_),
                    (#"^\s*(const|let|var)\s+\w+\s*=\s*(async\s+)?\("# , .function),
                ]
            case .go:
                return [
                    (#"^func\s+(\(\w+\s+\*?\w+\)\s+)?\w+"#, .function),
                    (#"^type\s+\w+\s+struct"#, .struct_),
                    (#"^type\s+\w+\s+interface"#, .struct_),
                ]
            case .rust:
                return [
                    (#"^\s*(pub(\(.*?\))?\s+)?(async\s+)?fn\s+\w+"#, .function),
                    (#"^\s*(pub(\(.*?\))?\s+)?struct\s+\w+"#, .struct_),
                    (#"^\s*(pub(\(.*?\))?\s+)?enum\s+\w+"#, .enum_),
                    (#"^\s*(pub(\(.*?\))?\s+)?impl(\s+\w+)?\s"#, .extension_),
                ]
            }
        }
    }

    private static func extractBraceChunks(_ lines: [String], file: String, lang: Lang) -> [CodeChunk] {
        let compiled: [(NSRegularExpression, CodeChunk.ChunkType)] = lang.specs.compactMap { (pat, type_) in
            guard let re = try? NSRegularExpression(pattern: pat) else { return nil }
            return (re, type_)
        }

        var chunks: [CodeChunk] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            var matchedType: CodeChunk.ChunkType? = nil
            for (re, type_) in compiled {
                if re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    matchedType = type_; break
                }
            }
            guard let chunkType = matchedType else { i += 1; continue }

            // Scan forward: collect signature (until first {) then count braces to find end
            var braces = 0
            var foundOpen = false
            var sigLines: [String] = []
            var bodyLines: [String] = []
            var endLine = i

            var j = i
            while j < lines.count && (j - i) < maxChunkLines {
                let l = lines[j]
                bodyLines.append(l)
                if !foundOpen { sigLines.append(l) }

                // Count braces, ignoring those inside strings is complex —
                // we use a simplified scan that handles most real code.
                var inString = false
                var prev: Character = " "
                for ch in l {
                    if ch == "\"" && prev != "\\" { inString.toggle() }
                    if !inString {
                        if ch == "{" { braces += 1; foundOpen = true }
                        else if ch == "}" { braces -= 1 }
                    }
                    prev = ch
                }

                if foundOpen && braces == 0 { endLine = j; break }
                j += 1
            }

            // Fallback for declarations without a body (protocol stubs, etc.)
            if !foundOpen { endLine = min(i + 1, lines.count - 1) }

            let lineCount = endLine - i + 1
            if lineCount >= minChunkLines {
                chunks.append(CodeChunk(
                    file: file,
                    startLine: i + 1,
                    endLine: endLine + 1,
                    name: extractName(from: line, type: chunkType),
                    type: chunkType,
                    signature: sigLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                    body: bodyLines.joined(separator: "\n")
                ))
            }

            // Advance past declaration line only — nested decls are captured on subsequent passes
            i += 1
        }
        return chunks
    }

    // MARK: - Indentation-based extraction (Python)

    private static func extractPythonChunks(_ lines: [String], file: String) -> [CodeChunk] {
        let funcRe  = try? NSRegularExpression(pattern: #"^(\s*)(async\s+)?def\s+(\w+)"#)
        let classRe = try? NSRegularExpression(pattern: #"^(\s*)class\s+(\w+)"#)

        var chunks: [CodeChunk] = []
        for i in 0..<lines.count {
            let line = lines[i]
            let ns = NSRange(line.startIndex..., in: line)
            var chunkType: CodeChunk.ChunkType? = nil
            var name = ""
            var baseIndent = 0

            if let m = funcRe?.firstMatch(in: line, range: ns) {
                chunkType = .function
                if let r = Range(m.range(at: 1), in: line) { baseIndent = line[r].count }
                if let r = Range(m.range(at: 3), in: line) { name = String(line[r]) }
            } else if let m = classRe?.firstMatch(in: line, range: ns) {
                chunkType = .class_
                if let r = Range(m.range(at: 1), in: line) { baseIndent = line[r].count }
                if let r = Range(m.range(at: 2), in: line) { name = String(line[r]) }
            }
            guard let type_ = chunkType else { continue }

            var bodyLines = [line]
            var endLine = i
            var j = i + 1
            while j < lines.count && (j - i) < maxChunkLines {
                let next = lines[j]
                let trimmed = next.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    let indent = next.prefix(while: { $0 == " " || $0 == "\t" }).count
                    if indent <= baseIndent { break }
                }
                bodyLines.append(next)
                endLine = j
                j += 1
            }

            if endLine - i >= minChunkLines {
                chunks.append(CodeChunk(
                    file: file,
                    startLine: i + 1,
                    endLine: endLine + 1,
                    name: name,
                    type: type_,
                    signature: line.trimmingCharacters(in: .whitespacesAndNewlines),
                    body: bodyLines.joined(separator: "\n")
                ))
            }
        }
        return chunks
    }

    // MARK: - Name extraction

    private static func extractName(from line: String, type: CodeChunk.ChunkType) -> String {
        let keywords: [String]
        switch type {
        case .function:   keywords = ["func ", "fn ", "def ", "function "]
        case .class_:     keywords = ["class "]
        case .struct_:    keywords = ["struct "]
        case .enum_:      keywords = ["enum "]
        case .extension_: keywords = ["extension "]
        }
        for kw in keywords {
            if let r = line.range(of: kw) {
                let after = line[r.upperBound...]
                let name = after.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" })
                if !name.isEmpty { return String(name) }
            }
        }
        return "unknown"
    }
}
