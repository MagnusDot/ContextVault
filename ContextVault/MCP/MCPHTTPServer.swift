import Network
import Foundation

// All methods run on @MainActor (inherited from SWIFT_DEFAULT_ACTOR_ISOLATION).
// NW callbacks dispatch back to MainActor via Task { @MainActor in ... }.
final class MCPHTTPServer {
    static let port: UInt16 = 9877

    private var listener: NWListener?
    private var sseSessions: [String: NWConnection] = [:]
    private let queue = DispatchQueue(label: "contextvault.http", qos: .utility)

    // Set by MCPServer before calling start()
    var onRPC: (([String: Any]) -> [String: Any])?
    var onClientCountChanged: ((Int) -> Void)?

    // MARK: - Lifecycle

    func start() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        guard let nwPort = NWEndpoint.Port(rawValue: Self.port),
              let l = try? NWListener(using: params, on: nwPort)
        else { return }

        listener = l
        l.newConnectionHandler = { [weak self] conn in
            Task { @MainActor [weak self] in self?.accept(conn) }
        }
        l.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        sseSessions.values.forEach { $0.cancel() }
        sseSessions.removeAll()
        onClientCountChanged?(0)
    }

    // MARK: - Incoming connection

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        HTTPRequestParser(connection: conn, queue: queue) { [weak self] method, path, body in
            Task { @MainActor [weak self] in
                self?.route(method: method, path: path, body: body, conn: conn)
            }
        }.start()
    }

    // MARK: - Routing

    private func route(method: String, path: String, body: Data?, conn: NWConnection) {
        let (pathOnly, query) = splitPath(path)

        switch (method, pathOnly) {

        // Streamable HTTP transport (MCP 2025-03-26) — used by Claude Desktop.
        // The client POSTs JSON-RPC directly and expects the response inline.
        case ("POST", "/mcp"):
            handleStreamableHTTP(body: body, conn: conn)

        // Legacy SSE transport — used by Claude Code (via ~/.claude.json type:sse).
        case ("GET", "/sse"):
            openSSEStream(conn: conn)

        case ("POST", "/messages"):
            sendHTTP(conn: conn, status: "202 Accepted", extra: corsHeaders, body: nil)
            guard let body,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            else { return }
            dispatchRPC(json, sessionId: query["sessionId"] ?? "")

        case ("OPTIONS", _):
            sendHTTP(conn: conn, status: "200 OK", extra: corsHeaders, body: nil)

        default:
            sendHTTP(conn: conn, status: "404 Not Found", extra: corsHeaders, body: "Not Found".data(using: .utf8))
        }
    }

    // MARK: - Streamable HTTP (Claude Desktop)

    private func handleStreamableHTTP(body: Data?, conn: NWConnection) {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else {
            sendHTTP(conn: conn, status: "400 Bad Request", extra: corsHeaders, body: nil)
            return
        }

        guard let handler = onRPC else {
            sendHTTP(conn: conn, status: "503 Service Unavailable", extra: corsHeaders, body: nil)
            return
        }

        let response = handler(json)
        let sessionId = UUID().uuidString
        let sessionHeader = "Mcp-Session-Id: \(sessionId)"

        // Notifications have no id and expect no response body (202 Accepted).
        if response.isEmpty {
            sendHTTP(conn: conn, status: "202 Accepted", extra: corsHeaders + [sessionHeader], body: nil)
            return
        }

        guard let data = try? JSONSerialization.data(withJSONObject: response) else {
            sendHTTP(conn: conn, status: "500 Internal Server Error", extra: corsHeaders, body: nil)
            return
        }

        sendHTTP(conn: conn, status: "200 OK",
                 extra: corsHeaders + ["Content-Type: application/json", sessionHeader],
                 body: data)
    }

    // MARK: - SSE stream

    private func openSSEStream(conn: NWConnection) {
        let sessionId = UUID().uuidString
        let sseHeaders = corsHeaders + [
            "Content-Type: text/event-stream",
            "Cache-Control: no-cache",
            "Connection: keep-alive"
        ]
        let headerBytes = httpHeaders(status: "200 OK", extra: sseHeaders)

        conn.send(content: headerBytes, completion: .contentProcessed { [weak self] error in
            guard error == nil else { conn.cancel(); return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sseSessions[sessionId] = conn
                self.onClientCountChanged?(self.sseSessions.count)

                let url = "http://localhost:\(MCPHTTPServer.port)/messages?sessionId=\(sessionId)"
                self.sendSSE(conn: conn, event: "endpoint", data: url) { [weak self] ok in
                    if !ok { Task { @MainActor [weak self] in self?.removeSession(sessionId) } }
                }
                self.monitorSSE(sessionId: sessionId, conn: conn)
            }
        })
    }

    private func monitorSSE(sessionId: String, conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, done, error in
            if done || error != nil {
                Task { @MainActor [weak self] in self?.removeSession(sessionId) }
            }
        }
    }

    private func removeSession(_ sessionId: String) {
        sseSessions[sessionId]?.cancel()
        sseSessions.removeValue(forKey: sessionId)
        onClientCountChanged?(sseSessions.count)
    }

    // MARK: - RPC dispatch

    private func dispatchRPC(_ req: [String: Any], sessionId: String) {
        guard let handler = onRPC,
              let conn = sseSessions[sessionId]
        else { return }

        let response = handler(req)
        guard !response.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: response),
              let str = String(data: data, encoding: .utf8)
        else { return }

        sendSSE(conn: conn, event: "message", data: str)
    }

    // MARK: - Helpers

    private func sendSSE(conn: NWConnection, event: String, data: String, completion: ((Bool) -> Void)? = nil) {
        let text = "event: \(event)\ndata: \(data)\n\n"
        conn.send(content: Data(text.utf8), completion: .contentProcessed { error in
            completion?(error == nil)
        })
    }

    private func sendHTTP(conn: NWConnection, status: String, extra: [String], body: Data?) {
        var response = httpHeaders(status: status, extra: ["Content-Length: \(body?.count ?? 0)"] + extra)
        if let body { response.append(body) }
        conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func httpHeaders(status: String, extra: [String]) -> Data {
        Data(("HTTP/1.1 \(status)\r\n" + extra.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    private var corsHeaders: [String] {
        [
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Methods: GET, POST, OPTIONS",
            "Access-Control-Allow-Headers: Content-Type"
        ]
    }

    private func splitPath(_ path: String) -> (String, [String: String]) {
        let parts = path.components(separatedBy: "?")
        let pathOnly = parts[0]
        var params: [String: String] = [:]
        if parts.count > 1 {
            for pair in parts[1].components(separatedBy: "&") {
                let kv = pair.components(separatedBy: "=")
                if kv.count == 2 {
                    let k = kv[0].removingPercentEncoding ?? kv[0]
                    let v = kv[1].removingPercentEncoding ?? kv[1]
                    params[k] = v
                }
            }
        }
        return (pathOnly, params)
    }
}

// MARK: - HTTP request accumulator

private final class HTTPRequestParser {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let onRequest: (String, String, Data?) -> Void
    private var buffer = Data()

    init(connection: NWConnection, queue: DispatchQueue, onRequest: @escaping (String, String, Data?) -> Void) {
        self.connection = connection
        self.queue = queue
        self.onRequest = onRequest
    }

    func start() { receive() }

    private func receive() {
        // Strong capture keeps the parser alive until the request completes.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] content, _, done, error in
            if let data = content { self.buffer.append(data) }
            if self.tryDeliver() { return }
            if !done && error == nil { self.receive() }
            else { self.connection.cancel() }
        }
    }

    private func tryDeliver() -> Bool {
        let crlf2 = Data("\r\n\r\n".utf8)
        guard let sep = buffer.range(of: crlf2) else { return false }

        guard let headerStr = String(data: buffer[..<sep.lowerBound], encoding: .utf8) else {
            connection.cancel(); return true
        }

        let lines = headerStr.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { connection.cancel(); return true }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).lowercased().trimmingCharacters(in: .whitespaces)
            let val = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = val
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = sep.upperBound
        guard buffer.count - (bodyStart - buffer.startIndex) >= contentLength else { return false }

        let body: Data? = contentLength > 0 ? Data(buffer[bodyStart..<(bodyStart + contentLength)]) : nil
        onRequest(parts[0], parts[1], body)
        return true
    }
}
