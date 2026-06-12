import Foundation

enum AutoDiscovery {
    private static let lockURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/claude/ide/contextvault.lock")

    static func register(wsPort: UInt16, httpPort: UInt16) {
        let dir = lockURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let payload: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "wsPort": wsPort,
            "httpPort": httpPort,
            "version": "1.0"
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted) else { return }
        do {
            try data.write(to: lockURL, options: .atomic)
        } catch {
            NSLog("[ContextVault] AutoDiscovery write failed: \(error)")
        }
    }

    static func unregister() {
        try? FileManager.default.removeItem(at: lockURL)
    }
}
