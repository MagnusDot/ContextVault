import SwiftUI

struct DiagnosticsView: View {
    @Environment(MCPServer.self) private var mcp
    @State private var checks: [DiagCheck] = []
    @State private var isRefreshing = false
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                serverStatusSection
                registrationSection
                activitySection
                actionsSection
            }
            .padding(24)
        }
        .navigationTitle("Diagnostics")
        .task { await refresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isRefreshing)
            }
        }
    }

    // MARK: - Sections

    private var serverStatusSection: some View {
        DiagSection(title: "MCP Server") {
            DiagRow(
                label: "WebSocket (Claude Code)",
                detail: "port \(MCPServer.wsPort)",
                status: mcp.isRunning ? .ok : .error,
                value: mcp.isRunning ? "Listening" : "Offline"
            )
            DiagRow(
                label: "HTTP/SSE (Claude Desktop)",
                detail: "port \(MCPServer.httpPort)",
                status: mcp.isRunning ? .ok : .error,
                value: mcp.isRunning ? "Listening" : "Offline"
            )
            DiagRow(
                label: "Connected clients",
                detail: nil,
                status: mcp.connectedClients > 0 ? .ok : .neutral,
                value: "\(mcp.connectedClients)"
            )
            if let err = mcp.lastError {
                DiagRow(label: "Last error", detail: nil, status: .error, value: err)
            }
        }
    }

    private var registrationSection: some View {
        DiagSection(title: "Auto-discovery") {
            ForEach(checks) { check in
                DiagRow(label: check.label, detail: check.detail, status: check.status, value: check.value)
            }
            if checks.isEmpty {
                ProgressView().padding(.vertical, 4)
            }
        }
    }

    private var activitySection: some View {
        DiagSection(title: "Activity") {
            DiagRow(
                label: "Total tool calls",
                detail: nil,
                status: .neutral,
                value: "\(mcp.totalToolCalls)"
            )
            DiagRow(
                label: "Tokens saved (est.)",
                detail: nil,
                status: .neutral,
                value: formattedTokens
            )
            DiagRow(
                label: "Last activity",
                detail: nil,
                status: .neutral,
                value: mcp.lastActivityAt.map { $0.formatted(.relative(presentation: .named)) } ?? "Never"
            )
        }
    }

    private var actionsSection: some View {
        DiagSection(title: "Actions") {
            HStack(spacing: 12) {
                Button("Restart MCP Server") {
                    Task {
                        // force restart
                        isRefreshing = true
                        await refresh()
                        isRefreshing = false
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!mcp.isRunning)

                Button(copied ? "Copied!" : "Copy Report") {
                    copyReport()
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 4)

            Text("If the server stays offline, try quitting and relaunching ContextVault from Xcode.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Checks

    @MainActor
    private func refresh() async {
        isRefreshing = true
        var result: [DiagCheck] = []

        // Lock file
        let lockURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/claude/ide/contextvault.lock")
        let lockExists = FileManager.default.fileExists(atPath: lockURL.path)
        result.append(DiagCheck(
            label: "Lock file",
            detail: "~/.config/claude/ide/contextvault.lock",
            status: lockExists ? .ok : .error,
            value: lockExists ? "Present" : "Missing — auto-discovery won't work"
        ))

        // Lock file contents
        if lockExists, let data = try? Data(contentsOf: lockURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let pid = json["pid"] as? Int {
            result.append(DiagCheck(
                label: "Lock file PID",
                detail: nil,
                status: pid == ProcessInfo.processInfo.processIdentifier ? .ok : .warning,
                value: "\(pid)\(pid == ProcessInfo.processInfo.processIdentifier ? " (this process)" : " (stale — different process)")"
            ))
        }

        // .claude.json registration
        let claudeJSON = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        var claudeRegistered = false
        if let data = try? Data(contentsOf: claudeJSON),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let servers = json["mcpServers"] as? [String: Any] {
            claudeRegistered = servers["contextvault"] != nil
        }
        result.append(DiagCheck(
            label: "Claude Code registration",
            detail: "~/.claude.json → mcpServers.contextvault",
            status: claudeRegistered ? .ok : .error,
            value: claudeRegistered ? "Registered" : "Missing — Claude Code won't find the server"
        ))

        // Write permission check
        let testURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/claude/ide/.cv_write_test")
        let canWrite = (try? "ok".write(to: testURL, atomically: true, encoding: .utf8)) != nil
        if canWrite { try? FileManager.default.removeItem(at: testURL) }
        result.append(DiagCheck(
            label: "Write permission",
            detail: "~/.config/claude/ide/",
            status: canWrite ? .ok : .error,
            value: canWrite ? "OK" : "Denied — sandbox may be blocking writes"
        ))

        checks = result
        isRefreshing = false
    }

    private func copyReport() {
        var lines = ["ContextVault Diagnostics — \(Date().formatted())"]
        lines.append("MCP Server: \(mcp.isRunning ? "running" : "offline")")
        lines.append("Clients: \(mcp.connectedClients)")
        lines.append("Tool calls: \(mcp.totalToolCalls)")
        if let err = mcp.lastError { lines.append("Last error: \(err)") }
        for check in checks {
            lines.append("\(check.label): \(check.value)")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private var formattedTokens: String {
        let t = mcp.estimatedTokensSaved
        if t >= 1_000_000 { return String(format: "%.1fM", Double(t) / 1_000_000) }
        if t >= 1_000     { return String(format: "%.1fk", Double(t) / 1_000) }
        return "\(t)"
    }
}

// MARK: - Supporting types

enum DiagStatus { case ok, warning, error, neutral }

struct DiagCheck: Identifiable {
    let id = UUID()
    let label: String
    let detail: String?
    let status: DiagStatus
    let value: String
}

private struct DiagSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }
}

private struct DiagRow: View {
    let label: String
    let detail: String?
    let status: DiagStatus
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.body)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fontDesign(.monospaced)
                }
            }

            Spacer()

            Text(value)
                .font(.caption)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 260, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        Divider().padding(.leading, 33)
    }

    private var statusColor: Color {
        switch status {
        case .ok:      .green
        case .warning: .orange
        case .error:   .red
        case .neutral: Color(.systemGray)
        }
    }

    private var valueColor: Color {
        switch status {
        case .ok:      .secondary
        case .warning: .orange
        case .error:   .red
        case .neutral: .secondary
        }
    }
}
