import Foundation
import CryptoKit

// Caches formatted MCP tool outputs keyed by a content hash.
// When underlying data is unchanged, returns the exact same bytes →
// Anthropic KV cache hits on repeated get_project_context calls.
// TTL matches Anthropic's prompt cache window (5 min).
final class CacheAligner {
    static let shared = CacheAligner()

    private struct Entry {
        let contentHash: String
        let output: String
        let storedAt: Date
    }

    private var cache: [String: Entry] = [:]
    private let lock = NSLock()
    static let ttl: TimeInterval = 270  // stay inside Anthropic's 5-min cache window

    private init() {}

    func get(key: String, contentHash: String) -> String? {
        lock.withLock {
            guard let e = cache[key],
                  e.contentHash == contentHash,
                  Date().timeIntervalSince(e.storedAt) < Self.ttl
            else { return nil }
            return e.output
        }
    }

    func set(key: String, contentHash: String, output: String) {
        lock.withLock { cache[key] = Entry(contentHash: contentHash, output: output, storedAt: Date()) }
    }

    // Stable hash over a note list: title + body-size + updatedAt.
    // Cheap to compute; changes whenever any note is written.
    func hash(for notes: [Note]) -> String {
        let combined = notes
            .sorted { $0.title < $1.title }
            .map { "\($0.title)|\($0.body.count)|\($0.updatedAt.timeIntervalSince1970)" }
            .joined(separator: "·")
        return sha12(combined)
    }

    func hash(for content: String) -> String { sha12(content) }

    var size: Int { lock.withLock { cache.count } }

    private func sha12(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(12).description
    }
}
