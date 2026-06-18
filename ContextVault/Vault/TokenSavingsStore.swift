import Foundation

struct TokenSavings: Codable {
    var totalSaved: Int = 0   // cumulative tokens saved vs grep+Read
    var callCount: Int = 0    // number of search_code calls
    var updatedAt: Date = Date()
}

// Thread-safe store — written from MCP background threads, read from MainActor views.
final class TokenSavingsStore {
    static let shared = TokenSavingsStore()
    private var cache: [String: TokenSavings] = [:]
    private let lock = NSLock()

    private init() {}

    func record(slug: String, savedTokens: Int) {
        lock.lock()
        var s = cache[slug] ?? load(slug: slug)
        s.totalSaved += max(0, savedTokens)
        s.callCount += 1
        s.updatedAt = Date()
        cache[slug] = s
        lock.unlock()
        persist(s, slug: slug)
    }

    func savings(slug: String) -> TokenSavings {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[slug] { return cached }
        let s = load(slug: slug)
        cache[slug] = s
        return s
    }

    // MARK: - Persistence

    private func path(slug: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".contextvault/\(slug)/savings.json")
    }

    private func load(slug: String) -> TokenSavings {
        guard let data = try? Data(contentsOf: path(slug: slug)),
              let s = try? JSONDecoder().decode(TokenSavings.self, from: data)
        else { return TokenSavings() }
        return s
    }

    private func persist(_ s: TokenSavings, slug: String) {
        let url = path(slug: slug)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? JSONEncoder().encode(s).write(to: url, options: .atomic)
    }
}
