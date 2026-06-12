import Foundation

struct CodeChunk: Codable, Identifiable {
    let file: String        // path relative to project root
    let startLine: Int      // 1-indexed
    let endLine: Int
    let name: String
    let type: ChunkType
    let signature: String   // declaration header only
    let body: String        // full text including signature

    var id: String { "\(file):\(startLine)" }
    var lineCount: Int { endLine - startLine + 1 }

    enum ChunkType: String, Codable {
        case function   = "func"
        case class_     = "class"
        case struct_    = "struct"
        case enum_      = "enum"
        case extension_ = "extension"
    }
}

struct ScoredChunk {
    let chunk: CodeChunk
    let score: Double
}

enum ProjectIndexState {
    case notIndexed
    case indexing(progress: Double, message: String)
    case indexed(fileCount: Int, chunkCount: Int, indexedAt: Date)
    case failed(String)

    var label: String {
        switch self {
        case .notIndexed:              return "Not indexed"
        case .indexing(_, let msg):    return msg
        case .indexed(_, let n, _):    return "\(n) chunks"
        case .failed:                  return "Error"
        }
    }

    var isIndexing: Bool {
        if case .indexing = self { return true }
        return false
    }

    var isIndexed: Bool {
        if case .indexed = self { return true }
        return false
    }

    var progress: Double {
        if case .indexing(let p, _) = self { return p }
        return isIndexed ? 1 : 0
    }
}
