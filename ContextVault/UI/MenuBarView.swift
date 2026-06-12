import SwiftUI

struct MenuBarView: View {
    @Environment(VaultManager.self) private var vault
    @Environment(MCPServer.self) private var mcp
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusHeader
            Divider()
            projectList
            Divider()
            tokensSaved
            Divider()
            footerActions
        }
        .padding(.vertical, 4)
    }

    // MARK: - Sections

    private var statusHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(mcp.isRunning ? (mcp.connectedClients > 0 ? Color.green : Color(.systemGray)) : Color.orange)
                .frame(width: 8, height: 8)
                .animation(.easeInOut(duration: 0.4), value: mcp.isRunning)

            Text(mcp.isRunning ? "MCP Server Running" : "MCP Server Offline")
                .font(.callout.weight(.medium))

            Spacer()

            if mcp.connectedClients > 0 {
                Text("\(mcp.connectedClients) client\(mcp.connectedClients > 1 ? "s" : "")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.green.opacity(0.12), in: Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var projectList: some View {
        Group {
            if vault.projects.isEmpty {
                Text("No projects yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            } else {
                ForEach(vault.projects.prefix(6)) { project in
                    MenuBarProjectRow(
                        project: project,
                        noteCount: vault.notes(for: project).count
                    ) {
                        openWindow(id: "main")
                    }
                }
            }
        }
    }

    private var tokensSaved: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .imageScale(.small)
                .foregroundStyle(.secondary)
            Text("~\(formattedTokens) tokens saved")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var footerActions: some View {
        VStack(spacing: 0) {
            MenuBarActionButton(label: "Open ContextVault", icon: "rectangle.stack") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            MenuBarActionButton(label: "Quit", icon: "power") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    // MARK: - Helpers

    private var formattedTokens: String {
        let t = mcp.estimatedTokensSaved
        if t >= 1_000_000 { return String(format: "%.1fM", Double(t) / 1_000_000) }
        if t >= 1_000     { return String(format: "%.1fk", Double(t) / 1_000) }
        return "\(t)"
    }
}

// MARK: - Sub-components

private struct MenuBarProjectRow: View {
    let project: Project
    let noteCount: Int
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.tint)
                    .imageScale(.small)
                    .frame(width: 16)
                Text(project.name)
                    .font(.body)
                Spacer()
                Text("\(noteCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(isHovered ? Color.accentColor.opacity(0.08) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct MenuBarActionButton: View {
    let label: String
    let icon: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .imageScale(.small)
                    .frame(width: 16)
                Text(label)
                    .font(.body)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(isHovered ? Color(.controlBackgroundColor) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
