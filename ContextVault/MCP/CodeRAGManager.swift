import Foundation
import Observation

@Observable
final class CodeRAGManager {

    static let shared = CodeRAGManager()

    private(set) var states: [String: ProjectIndexState] = [:]

    nonisolated(unsafe) private var indexes: [String: BM25Index] = [:]
    private let indexLock = NSLock()
    private var activeTasks: [String: Task<Void, Never>] = [:]

    private init() {}

    // MARK: - Public API (MainActor)

    func reindex(project: Project) {
        activeTasks[project.slug]?.cancel()
        states[project.slug] = .indexing(progress: 0, message: "Scanning files…")

        let slug = project.slug
        let rootPath = project.rootPath

        activeTasks[slug] = Task {
            // Heavy I/O off main thread; progress dispatched back to MainActor
            let result = await Task.detached(priority: .utility) {
                CodeChunker.chunkProject(at: rootPath) { progress, msg in
                    DispatchQueue.main.async {
                        if case .indexing = CodeRAGManager.shared.states[slug] {
                            CodeRAGManager.shared.states[slug] = .indexing(progress: progress, message: msg)
                        }
                    }
                }
            }.value

            if Task.isCancelled { return }

            let idx = BM25Index(chunks: result.chunks)
            indexLock.withLock { indexes[slug] = idx }
            states[slug] = .indexed(
                fileCount: result.fileCount,
                chunkCount: result.chunks.count,
                indexedAt: Date()
            )

            let chunks = result.chunks
            Task.detached(priority: .background) {
                Self.persist(chunks: chunks, slug: slug)
            }
        }
    }

    func cancelIndexing(slug: String) {
        activeTasks[slug]?.cancel()
        activeTasks[slug] = nil
        if case .indexing = states[slug] {
            states[slug] = .notIndexed
        }
    }

    func loadIfNeeded(project: Project) {
        guard states[project.slug] == nil else { return }
        states[project.slug] = .notIndexed

        let slug = project.slug
        Task.detached(priority: .background) {
            guard let chunks = Self.load(slug: slug) else { return }
            let idx = BM25Index(chunks: chunks)
            await MainActor.run {
                self.indexLock.withLock { self.indexes[slug] = idx }
                self.states[slug] = .indexed(
                    fileCount: Set(chunks.map(\.file)).count,
                    chunkCount: chunks.count,
                    indexedAt: Self.persistedDate(slug: slug) ?? Date()
                )
            }
        }
    }

    // MARK: - Thread-safe search (called from MCP tools on any thread)

    nonisolated func search(slug: String, query: String, topK: Int = 8) -> [ScoredChunk] {
        indexLock.withLock { indexes[slug] }?.search(query: query, topK: topK) ?? []
    }

    nonisolated func chunk(slug: String, file: String, startLine: Int) -> CodeChunk? {
        indexLock.withLock { indexes[slug] }?.chunk(file: file, startLine: startLine)
    }

    nonisolated func isIndexed(slug: String) -> Bool {
        indexLock.withLock { indexes[slug] } != nil
    }

    nonisolated func bm25(slug: String) -> BM25Index? {
        indexLock.withLock { indexes[slug] }
    }

    // MARK: - Persistence

    private static func storageURL(slug: String) -> URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".contextvault")
            .appendingPathComponent(slug)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("code-index.json")
    }

    private static func persist(chunks: [CodeChunk], slug: String) {
        let url = storageURL(slug: slug)
        guard let data = try? JSONEncoder().encode(chunks) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func load(slug: String) -> [CodeChunk]? {
        let url = storageURL(slug: slug)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([CodeChunk].self, from: data)
    }

    private static func persistedDate(slug: String) -> Date? {
        let url = storageURL(slug: slug)
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
