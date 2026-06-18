import Foundation

// Output format (one line per file):
//   path/file.swift: C:MyClass@6 F:myFunc@21 S:MyStruct@40
// Type prefixes: F=func/def M=method C=class S=struct E=enum P=protocol I=interface T=type X=extension
enum CodeIndexer {

    struct FileIndex {
        let relativePath: String
        let symbols: [(type: String, name: String, line: Int)]
    }

    // MARK: - Public

    static func index(at rootPath: String, extensions: [String]? = nil, maxDepth: Int = 8) -> [FileIndex] {
        let exts = extensions ?? ["swift", "ts", "tsx", "js", "jsx", "py", "go", "rs", "rb", "kt"]
        let fm = FileManager.default
        let root = URL(fileURLWithPath: rootPath)

        var results: [FileIndex] = []
        scanDirectory(root, root: root, fm: fm, exts: Set(exts), depth: 0, maxDepth: maxDepth, results: &results)
        return results.sorted { $0.relativePath < $1.relativePath }
    }

    static func format(_ indexes: [FileIndex], rootPath: String) -> String {
        guard !indexes.isEmpty else { return "(no source files found)" }
        let total = indexes.reduce(0) { $0 + $1.symbols.count }
        var lines = ["idx:\(indexes.count)f \(total)sym"]
        for fi in indexes {
            guard !fi.symbols.isEmpty else { continue }
            let syms = fi.symbols.map { "\($0.type):\($0.name)@\($0.line)" }.joined(separator: " ")
            lines.append("\(fi.relativePath): \(syms)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Directory walk

    private static let skipDirs: Set<String> = [
        "node_modules", ".git", ".build", "build", "dist", "DerivedData",
        ".gradle", "Pods", ".swiftpm", "__pycache__", ".venv", "venv",
        "vendor", "target", ".next", ".nuxt", "coverage"
    ]

    private static func scanDirectory(
        _ dir: URL, root: URL, fm: FileManager,
        exts: Set<String>, depth: Int, maxDepth: Int,
        results: inout [FileIndex]
    ) {
        guard depth <= maxDepth else { return }
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: .skipsHiddenFiles
        ) else { return }

        for entry in entries {
            let name = entry.lastPathComponent
            guard !skipDirs.contains(name) else { continue }

            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDir {
                scanDirectory(entry, root: root, fm: fm, exts: exts, depth: depth + 1, maxDepth: maxDepth, results: &results)
            } else if exts.contains(entry.pathExtension) {
                if let fi = parseFile(entry, root: root) {
                    results.append(fi)
                }
            }
        }
    }

    // MARK: - File parsing

    private static func parseFile(_ url: URL, root: URL) -> FileIndex? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let rel = String(url.path.dropFirst(root.path.count + 1))
        let ext = url.pathExtension
        let symbols = extractSymbols(from: content, ext: ext)
        return FileIndex(relativePath: rel, symbols: symbols)
    }

    private static func extractSymbols(from content: String, ext: String) -> [(type: String, name: String, line: Int)] {
        switch ext {
        case "swift":      return parseSwift(content)
        case "ts", "tsx":  return parseTypeScript(content)
        case "js", "jsx":  return parseJavaScript(content)
        case "py":         return parsePython(content)
        case "go":         return parseGo(content)
        case "rs":         return parseRust(content)
        case "kt":         return parseKotlin(content)
        default:           return []
        }
    }

    // MARK: - Language parsers

    private static func parseSwift(_ src: String) -> [(type: String, name: String, line: Int)] {
        let patterns: [(String, String)] = [
            ("C", #"^\s*(?:public |private |internal |open |final |@Observable\s*\n?\s*)*class\s+(\w+)"#),
            ("S", #"^\s*(?:public |private |internal )*struct\s+(\w+)"#),
            ("E", #"^\s*(?:public |private |internal )*enum\s+(\w+)"#),
            ("P", #"^\s*(?:public |private |internal )*protocol\s+(\w+)"#),
            ("X", #"^\s*extension\s+(\w+)"#),
            ("F", #"^\s*(?:public |private |internal |static |class |override |async |mutating )*func\s+(\w+)"#),
        ]
        return scan(src, patterns: patterns)
    }

    private static func parseTypeScript(_ src: String) -> [(type: String, name: String, line: Int)] {
        let patterns: [(String, String)] = [
            ("C", #"^\s*(?:export\s+)?(?:abstract\s+)?class\s+(\w+)"#),
            ("I", #"^\s*(?:export\s+)?interface\s+(\w+)"#),
            ("T", #"^\s*(?:export\s+)?type\s+(\w+)\s*="#),
            ("F", #"^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s+(\w+)"#),
            ("F", #"^\s*(?:export\s+)?const\s+(\w+)\s*=\s*(?:async\s*)?\("#),
            ("F", #"^\s*(?:public|private|protected|static|async)(?:\s+(?:public|private|protected|static|async))*\s+(\w+)\s*\("#),
        ]
        return scan(src, patterns: patterns)
    }

    private static func parseJavaScript(_ src: String) -> [(type: String, name: String, line: Int)] {
        let patterns: [(String, String)] = [
            ("C", #"^\s*(?:export\s+)?class\s+(\w+)"#),
            ("F", #"^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s+(\w+)"#),
            ("F", #"^\s*(?:export\s+)?const\s+(\w+)\s*=\s*(?:async\s*)?\("#),
        ]
        return scan(src, patterns: patterns)
    }

    private static func parsePython(_ src: String) -> [(type: String, name: String, line: Int)] {
        let patterns: [(String, String)] = [
            ("C", #"^class\s+(\w+)"#),
            ("F", #"^\s*(?:async\s+)?def\s+(\w+)"#),
        ]
        return scan(src, patterns: patterns)
    }

    private static func parseGo(_ src: String) -> [(type: String, name: String, line: Int)] {
        let patterns: [(String, String)] = [
            ("S", #"^type\s+(\w+)\s+struct"#),
            ("I", #"^type\s+(\w+)\s+interface"#),
            ("F", #"^func\s+(\w+)\s*\("#),
            ("M", #"^func\s+\([^)]+\)\s+(\w+)\s*\("#),
        ]
        return scan(src, patterns: patterns)
    }

    private static func parseRust(_ src: String) -> [(type: String, name: String, line: Int)] {
        let patterns: [(String, String)] = [
            ("S", #"^\s*(?:pub\s+)?struct\s+(\w+)"#),
            ("E", #"^\s*(?:pub\s+)?enum\s+(\w+)"#),
            ("T", #"^\s*(?:pub\s+)?trait\s+(\w+)"#),
            ("F", #"^\s*(?:pub\s+)?(?:async\s+)?fn\s+(\w+)"#),
        ]
        return scan(src, patterns: patterns)
    }

    private static func parseKotlin(_ src: String) -> [(type: String, name: String, line: Int)] {
        let patterns: [(String, String)] = [
            ("C", #"^\s*(?:data\s+|open\s+|abstract\s+)?class\s+(\w+)"#),
            ("I", #"^\s*interface\s+(\w+)"#),
            ("F", #"^\s*(?:suspend\s+)?fun\s+(\w+)"#),
        ]
        return scan(src, patterns: patterns)
    }

    // MARK: - Core scanner

    private static func scan(_ src: String, patterns: [(String, String)]) -> [(type: String, name: String, line: Int)] {
        let lines = src.components(separatedBy: "\n")
        var results: [(String, String, Int)] = []
        let compiled = patterns.compactMap { (type, pattern) -> (String, NSRegularExpression)? in
            guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (type, re)
        }

        for (lineIdx, line) in lines.enumerated() {
            for (type, re) in compiled {
                let range = NSRange(line.startIndex..., in: line)
                if let match = re.firstMatch(in: line, range: range),
                   match.numberOfRanges > 1,
                   let nameRange = Range(match.range(at: 1), in: line) {
                    let name = String(line[nameRange])
                    guard name.count >= 2, !name.hasPrefix("_") else { continue }
                    results.append((type, name, lineIdx + 1))
                    break
                }
            }
        }
        return results
    }
}
