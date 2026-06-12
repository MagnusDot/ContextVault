import SwiftUI

struct ConnectionStatusView: View {
    @Environment(MCPServer.self) private var mcp

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .animation(.easeInOut(duration: 0.3), value: mcp.isRunning)
            Text(statusLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var statusColor: Color {
        guard mcp.isRunning else { return .orange }
        return mcp.connectedClients > 0 ? .green : Color(.systemGray)
    }

    private var statusLabel: String {
        guard mcp.isRunning else { return "MCP Offline" }
        return mcp.connectedClients > 0 ? "\(mcp.connectedClients) connected" : "MCP Ready"
    }
}
