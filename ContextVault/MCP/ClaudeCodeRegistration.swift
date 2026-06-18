import Foundation

enum ClaudeCodeRegistration {
    private static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    static func register() {
        var config = readConfig()
        var mcpServers = config["mcpServers"] as? [String: Any] ?? [:]
        mcpServers["contextvault"] = [
            "type": "sse",
            "url": "http://localhost:\(MCPHTTPServer.port)/sse"
        ]
        config["mcpServers"] = mcpServers
        writeConfig(config)
    }

    static func unregister() {
        var config = readConfig()
        guard var mcpServers = config["mcpServers"] as? [String: Any] else { return }
        mcpServers.removeValue(forKey: "contextvault")
        config["mcpServers"] = mcpServers
        writeConfig(config)
    }

    // MARK: - Helpers

    private static func readConfig() -> [String: Any] {
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    private static func writeConfig(_ config: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) else { return }
        do {
            try data.write(to: configURL, options: .atomic)
        } catch {
            NSLog("[ContextVault] ClaudeCodeRegistration write failed: \(error)")
        }
    }
}
