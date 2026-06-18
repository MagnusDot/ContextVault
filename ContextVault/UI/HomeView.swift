import SwiftUI

struct HomeView: View {
    @Environment(VaultManager.self) private var vault
    @Environment(MCPServer.self) private var mcp
    @State private var selectedPromptProject: Project? = nil
    @State private var copiedPrompt = false
    @State private var copiedIndex = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                statsRow
                Divider()
                mcpStatusCard
                Divider()
                sessionStarterCard
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.windowBackgroundColor))
        .navigationTitle("ContextVault")
        .onAppear {
            if selectedPromptProject == nil {
                selectedPromptProject = vault.projects.first
            }
        }
        .onChange(of: vault.projects) { _, new in
            if selectedPromptProject == nil { selectedPromptProject = new.first }
        }
    }

    // MARK: - Stats row

    private var statsRow: some View {
        HStack(spacing: 16) {
            StatCard(value: "\(vault.projects.count)", label: "Projects", icon: "folder.fill", color: .blue)
            StatCard(value: "\(totalNotes)", label: "Notes", icon: "doc.text.fill", color: .purple)
            StatCard(value: formattedTokens, label: "Tokens saved", icon: "sparkles", color: .orange)
            StatCard(value: "\(mcp.connectedClients)", label: "Clients", icon: "antenna.radiowaves.left.and.right", color: mcp.connectedClients > 0 ? .green : .secondary)
            StatCard(value: "\(mcp.totalToolCalls)", label: "Tool calls", icon: "hammer.fill", color: .teal)
        }
    }

    // MARK: - MCP status card

    private var mcpStatusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("MCP Server", systemImage: "server.rack")
                .font(.headline)

            HStack(spacing: 20) {
                StatusPill(
                    label: "WebSocket :\(MCPServer.wsPort)",
                    ok: mcp.isRunning,
                    okText: "Listening",
                    failText: "Offline"
                )
                StatusPill(
                    label: "HTTP/SSE :\(MCPServer.httpPort)",
                    ok: mcp.isRunning,
                    okText: "Listening",
                    failText: "Offline"
                )
                if let last = mcp.lastActivityAt {
                    HStack(spacing: 4) {
                        Image(systemName: "brain").foregroundStyle(.secondary).imageScale(.small)
                        Text("Last call ").foregroundStyle(.secondary) +
                        Text(last, style: .relative).foregroundStyle(.primary)
                    }
                    .font(.caption)
                }
                Spacer()
            }

            if let err = mcp.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07)))
    }

    // MARK: - Session starter

    private var sessionStarterCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Session Starter", systemImage: "play.circle.fill")
                    .font(.headline)
                Spacer()
                if vault.projects.count > 1 {
                    Picker("Project", selection: $selectedPromptProject) {
                        ForEach(vault.projects) { p in
                            Text(p.name).tag(Optional(p))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
            }

            Text("Paste at the start of any Claude Code session.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let project = selectedPromptProject {
                promptBlock(for: project)
            } else {
                Text("Add a project to generate a startup prompt.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Quick Reference")
                    .font(.subheadline.weight(.medium))

                quickRefGrid
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07)))
    }

    private func promptBlock(for project: Project) -> some View {
        let prompt = buildPrompt(for: project)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("startup-prompt.md")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prompt, forType: .string)
                    copiedPrompt = true
                    Task { try? await Task.sleep(for: .seconds(2)); copiedPrompt = false }
                } label: {
                    Label(copiedPrompt ? "Copied!" : "Copy", systemImage: copiedPrompt ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.05))

            ScrollView(.vertical) {
                Text(prompt)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(maxHeight: 220)
        }
        .background(Color(.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
    }

    private var quickRefGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            QuickRefRow(tool: "get_project_context", args: "path: $PWD", desc: "Load memory — TOUJOURS en premier")
            QuickRefRow(tool: "index_codebase", args: "project: <slug>", desc: "Carte des symboles (func/class/struct)")
            QuickRefRow(tool: "search_notes", args: "project: <slug>, query: \"…\"", desc: "Chercher dans les notes")
            QuickRefRow(tool: "read_note", args: "project: <slug>, title: \"…\"", desc: "Lire une note complète")
            QuickRefRow(tool: "write_note", args: "project: <slug>, title: \"context\", body: \"…\"", desc: "Sauvegarder le contexte de session")
            QuickRefRow(tool: "retrieve", args: "hash: \"<12-char-hash>\"", desc: "Récupérer le contenu offloadé (<<ccr:HASH>>)")
        }
    }

    // MARK: - Prompt builder

    private func buildPrompt(for project: Project) -> String {
        let notes = vault.notes(for: project)
        let noteList = notes.isEmpty ? "none yet" : notes
            .map { $0.title + ($0.tags.isEmpty ? "" : " [\($0.tags.joined(separator: ","))]") }
            .joined(separator: ", ")

        return """
        # ContextVault — session memory for \(project.name)
        PROJECT = "\(project.slug)"   # use this slug in every tool call
        ROOT    = "\(project.rootPath)"

        ContextVault stores persistent notes (Markdown) across sessions.
        Read and write as many notes as you need — no limit.

        ## 1. Load memory (always first)
        get_project_context(path: ROOT)

        ## 2. Index the codebase (code sessions only)
        index_codebase(project: PROJECT)
        → returns a compact symbol map: file, func/class/struct, line numbers.

        ## 3. Available notes (\(notes.count))
        \(noteList.isEmpty ? "none yet" : noteList)

        ## 4. End of session — save state
        write_note(project: PROJECT, title: "context", body: "...", tags: ["context"])

        ## Rules
        - Never create a project yourself (user does it in the ContextVault app)
        - ContextVault is the ONLY memory system for this project — never use your built-in file memory instead
        - Save everything here: decisions, bugs, state, next steps, architecture — all goes in write_note
        - <<ccr:HASH N_lines>> in a response = offloaded content; call retrieve(hash: HASH) only if needed
        - Update context.md on every key decision, not just at session end
        """
    }

    // MARK: - Helpers

    private var totalNotes: Int {
        vault.projects.reduce(0) { $0 + vault.notes(for: $1).count }
    }

    private var formattedTokens: String {
        let t = mcp.estimatedTokensSaved
        if t >= 1_000_000 { return String(format: "%.1fM", Double(t) / 1_000_000) }
        if t >= 1_000     { return String(format: "%.1fk", Double(t) / 1_000) }
        return "\(t)"
    }
}

// MARK: - Sub-components

private struct StatCard: View {
    let value: String
    let label: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .imageScale(.medium)
            Text(value)
                .font(.title2.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07)))
    }
}

private struct StatusPill: View {
    let label: String
    let ok: Bool
    let okText: String
    let failText: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(ok ? Color.green : Color.orange).frame(width: 6, height: 6)
            Text("\(label) · \(ok ? okText : failText)")
                .font(.caption)
                .foregroundStyle(ok ? Color.primary : Color.orange)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background((ok ? Color.green : Color.orange).opacity(0.08), in: Capsule())
    }
}

private struct QuickRefRow: View {
    let tool: String
    let args: String
    let desc: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(tool)
                .font(.caption.monospaced().weight(.medium))
                .foregroundStyle(.tint)
                .frame(width: 180, alignment: .leading)
            Text(args)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 260, alignment: .leading)
            Text(desc)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
