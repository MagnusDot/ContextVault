import Foundation
import CryptoKit

// Compress-Cache-Retrieve store.
// Full content is cached locally keyed by a 12-char SHA-256 prefix.
// The LLM receives a compressed view + a marker; it calls retrieve(hash:)
// only if it needs the full original.
final class CCRStore {
    static let shared = CCRStore()

    private var store: [String: String] = [:]
    private let lock = NSLock()

    private init() {}

    func put(_ content: String) -> String {
        let hash = sha12(content)
        lock.withLock { store[hash] = content }
        return hash
    }

    func get(_ hash: String) -> String? {
        lock.withLock { store[hash] }
    }

    func evict(_ hash: String) {
        lock.withLock { store.removeValue(forKey: hash) }
    }

    var count: Int { lock.withLock { store.count } }

    private func sha12(_ s: String) -> String {
        let data = Data(s.utf8)
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(12).description
    }
}
