import Network
import Foundation
import CryptoKit

actor WebSocketConnection {
    private let connection: NWConnection
    private var upgraded = false
    private var buffer = Data()

    let onMessage: @MainActor (String, WebSocketConnection) -> Void
    let onClose: @MainActor (WebSocketConnection) -> Void

    init(
        connection: NWConnection,
        onMessage: @escaping @MainActor (String, WebSocketConnection) -> Void,
        onClose: @escaping @MainActor (WebSocketConnection) -> Void
    ) {
        self.connection = connection
        self.onMessage = onMessage
        self.onClose = onClose
    }

    func start() {
        connection.start(queue: .global(qos: .utility))
        receive()
    }

    func close() {
        connection.cancel()
    }

    func send(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        connection.send(content: encodeFrame(data: data, opcode: 0x1), completion: .idempotent)
    }

    // MARK: - Receive loop

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task {
                await self.received(data: data, isComplete: isComplete, error: error)
            }
        }
    }

    private func received(data: Data?, isComplete: Bool, error: Error?) {
        if let data, !data.isEmpty {
            buffer.append(data)
            if !upgraded {
                tryUpgrade()
            } else {
                processFrames()
            }
        }
        if isComplete || error != nil {
            let cb = onClose
            Task { @MainActor in cb(self) }
        } else {
            receive()
        }
    }

    // MARK: - WebSocket handshake

    private func tryUpgrade() {
        guard let str = String(data: buffer, encoding: .utf8), str.contains("\r\n\r\n") else { return }
        let lines = str.components(separatedBy: "\r\n")
        guard let keyLine = lines.first(where: { $0.hasPrefix("Sec-WebSocket-Key:") }) else { return }
        let key = keyLine.components(separatedBy: ": ").dropFirst().joined().trimmingCharacters(in: .whitespaces)

        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .idempotent)
        upgraded = true
        buffer = Data()
    }

    // MARK: - Frame parsing

    private func processFrames() {
        while buffer.count >= 2 {
            let b0 = buffer[0], b1 = buffer[1]
            let opcode = b0 & 0x0F
            let masked = (b1 & 0x80) != 0
            var payloadLen = Int(b1 & 0x7F)
            var headerLen = 2

            if payloadLen == 126 {
                guard buffer.count >= 4 else { return }
                payloadLen = Int(buffer[2]) << 8 | Int(buffer[3])
                headerLen = 4
            } else if payloadLen == 127 {
                guard buffer.count >= 10 else { return }
                payloadLen = (2..<10).reduce(0) { ($0 << 8) | Int(buffer[$1]) }
                headerLen = 10
            }

            let maskLen = masked ? 4 : 0
            let total = headerLen + maskLen + payloadLen
            guard buffer.count >= total else { return }

            var payload = Data(buffer[headerLen + maskLen ..< total])
            if masked {
                for i in 0..<payload.count { payload[i] ^= buffer[headerLen + (i % 4)] }
            }
            buffer.removeFirst(total)

            switch opcode {
            case 0x1:
                if let text = String(data: payload, encoding: .utf8) {
                    let cb = onMessage
                    Task { @MainActor in cb(text, self) }
                }
            case 0x8:
                connection.cancel()
                let cb = onClose
                Task { @MainActor in cb(self) }
                return
            case 0x9:
                connection.send(content: encodeFrame(data: payload, opcode: 0xA), completion: .idempotent)
            default:
                break
            }
        }
    }

    // MARK: - Frame encoding

    private func encodeFrame(data: Data, opcode: UInt8) -> Data {
        var frame = Data()
        frame.append(0x80 | opcode)
        if data.count < 126 {
            frame.append(UInt8(data.count))
        } else if data.count < 65536 {
            frame.append(126)
            frame.append(UInt8(data.count >> 8))
            frame.append(UInt8(data.count & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((data.count >> shift) & 0xFF))
            }
        }
        frame.append(contentsOf: data)
        return frame
    }
}
