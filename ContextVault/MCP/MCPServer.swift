import Network
import Foundation
import Observation

@Observable
final class MCPServer {
    static let wsPort: UInt16 = 9876
    static let httpPort: UInt16 = 9877

    private(set) var isRunning = false
    private(set) var connectedClients = 0
    private(set) var estimatedTokensSaved = 0
    private(set) var lastError: String? = nil
    private(set) var lastActivityAt: Date? = nil
    private(set) var totalToolCalls = 0

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: WebSocketConnection] = [:]
    private let queue = DispatchQueue(label: "contextvault.mcp", qos: .utility)
    private var tools: MCPTools?
    private var httpServer = MCPHTTPServer()
    private var httpClientCount = 0

    func start(vault: VaultManager) {
        guard listener == nil else { return }
        tools = MCPTools(vault: vault)

        httpServer.onRPC = { [weak self] req in self?.processJSONRPC(req) ?? [:] }
        httpServer.onClientCountChanged = { [weak self] count in
            guard let self else { return }
            self.httpClientCount = count
            self.connectedClients = self.connections.count + count
        }
        httpServer.start()

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        guard let port = NWEndpoint.Port(rawValue: Self.wsPort),
              let l = try? NWListener(using: params, on: port) else {
            return
        }
        listener = l

        l.newConnectionHandler = { [weak self] conn in
            Task { @MainActor [weak self] in self?.accept(conn) }
        }

        l.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isRunning = true
                    self.lastError = nil
                    AutoDiscovery.register(wsPort: Self.wsPort, httpPort: Self.httpPort)
                    ClaudeCodeRegistration.register()
                case .failed(let err):
                    self.isRunning = false
                    self.lastError = err.localizedDescription
                    AutoDiscovery.unregister()
                    ClaudeCodeRegistration.unregister()
                case .cancelled:
                    self.isRunning = false
                    AutoDiscovery.unregister()
                    ClaudeCodeRegistration.unregister()
                default:
                    break
                }
            }
        }

        l.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        connections.values.forEach { conn in Task { await conn.close() } }
        connections.removeAll()
        httpServer.stop()
        AutoDiscovery.unregister()
        ClaudeCodeRegistration.unregister()
        isRunning = false
        connectedClients = 0
    }

    // MARK: - Connection management

    private func accept(_ nwConnection: NWConnection) {
        let conn = WebSocketConnection(
            connection: nwConnection,
            onMessage: { [weak self] text, conn in self?.handle(text, from: conn) },
            onClose:   { [weak self] conn in self?.remove(conn) }
        )
        connections[ObjectIdentifier(conn)] = conn
        connectedClients = connections.count + httpClientCount
        Task { await conn.start() }
    }

    private func remove(_ conn: WebSocketConnection) {
        connections.removeValue(forKey: ObjectIdentifier(conn))
        connectedClients = connections.count + httpClientCount
    }

    // MARK: - JSON-RPC dispatch

    private func handle(_ message: String, from connection: WebSocketConnection) {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        let response = processJSONRPC(json)
        guard !response.isEmpty,
              let responseData = try? JSONSerialization.data(withJSONObject: response),
              let responseStr = String(data: responseData, encoding: .utf8)
        else { return }

        Task { await connection.send(responseStr) }
    }

    func processJSONRPC(_ req: [String: Any]) -> [String: Any] {
        let id     = req["id"]
        let method = req["method"] as? String ?? ""
        let params = req["params"] as? [String: Any] ?? [:]

        func ok(_ result: Any) -> [String: Any] {
            var r: [String: Any] = ["jsonrpc": "2.0", "result": result]
            if let id { r["id"] = id }
            return r
        }

        func fail(_ code: Int, _ msg: String) -> [String: Any] {
            var r: [String: Any] = ["jsonrpc": "2.0", "error": ["code": code, "message": msg]]
            if let id { r["id"] = id }
            return r
        }

        switch method {
        case "initialize":
            return ok([
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "ContextVault", "version": "1.0"]
            ])

        case "notifications/initialized":
            return [:]

        case "tools/list":
            return ok(["tools": MCPToolDefinitions.all])

        case "tools/call":
            guard let name = params["name"] as? String,
                  let args = params["arguments"] as? [String: Any]
            else { return fail(-32602, "Invalid params: expected name and arguments") }

            let result = tools?.handle(name: name, arguments: args) ?? .err("Server not initialized")
            estimatedTokensSaved += estimateTokens(result.content)
            totalToolCalls += 1
            lastActivityAt = Date()

            return ok([
                "content": [["type": "text", "text": result.content]],
                "isError": result.isError
            ])

        default:
            return fail(-32601, "Method not found: \(method)")
        }
    }

    private func estimateTokens(_ text: String) -> Int {
        max(1, text.count / 4)
    }
}
