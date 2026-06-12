import SwiftUI
import Combine

struct CodeIndexView: View {
    @Environment(VaultManager.self) private var vault
    @State private var rag = CodeRAGManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if vault.projects.isEmpty {
                emptyState
            } else {
                projectList
            }
        }
        .task {
            for project in vault.projects {
                rag.loadIfNeeded(project: project)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Label("Code Index", systemImage: "magnifyingglass.circle.fill")
                .font(.headline)
            Spacer()
            Button {
                for project in vault.projects {
                    rag.reindex(project: project)
                }
            } label: {
                Label("Re-index All", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(vault.projects.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Project list

    private var projectList: some View {
        ScrollView {
            VStack(spacing: 1) {
                ForEach(vault.projects) { project in
                    ProjectIndexRow(project: project, rag: rag)
                    Divider().padding(.leading, 16)
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Projects", systemImage: "folder")
        } description: {
            Text("Add a project in ContextVault to start indexing its code.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Per-project row

private struct ProjectIndexRow: View {
    let project: Project
    let rag: CodeRAGManager
    @State private var stateSnapshot: ProjectIndexState = .notIndexed

    var body: some View {
        HStack(spacing: 12) {
            // Project info
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                    .font(.body)
                    .fontWeight(.medium)
                Text(project.rootPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // Status + controls
            HStack(spacing: 8) {
                statusPill
                actionButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .onReceive(
            Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
        ) { _ in
            if let s = rag.states[project.slug] { stateSnapshot = s }
        }
        .task {
            if let s = rag.states[project.slug] { stateSnapshot = s }
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        switch stateSnapshot {
        case .notIndexed:
            StateBadge("Not indexed", color: .secondary)

        case .indexing(let progress, let msg):
            HStack(spacing: 6) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 60)
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

        case .indexed(let files, let chunks, let date):
            HStack(spacing: 6) {
                StateBadge("✓ \(chunks) chunks", color: .green)
                Text("\(files) files · \(date.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

        case .failed(let msg):
            StateBadge("Error: \(msg)", color: .red)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if case .indexing = stateSnapshot {
            Button {
                rag.cancelIndexing(slug: project.slug)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Cancel indexing")
        } else {
            Button {
                rag.reindex(project: project)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Re-index this project")
        }
    }
}

// MARK: - Small badge

private struct StateBadge: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color == .secondary ? .secondary : color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.1), in: Capsule())
    }
}
