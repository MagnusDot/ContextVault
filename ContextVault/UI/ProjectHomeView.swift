import SwiftUI

struct ProjectHomeView: View {
    let project: Project
    @Environment(VaultManager.self) private var vault
    @State private var rag = CodeRAGManager.shared
    @State private var selectedTab: Tab = .overview

    enum Tab: String, CaseIterable {
        case overview   = "Overview"
        case explorer   = "RAG Explorer"
    }

    private var notes: [Note] { vault.notes(for: project) }
    private var indexState: ProjectIndexState { rag.states[project.slug] ?? .notIndexed }
    @State private var savings: TokenSavings = TokenSavings()

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar

            HStack(spacing: 0) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        HStack(spacing: 5) {
                            if tab == .explorer {
                                Image(systemName: "magnifyingglass.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(indexState.isIndexed ? .green : .secondary)
                            }
                            Text(tab.rawValue)
                                .font(.caption)
                                .fontWeight(selectedTab == tab ? .semibold : .regular)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            selectedTab == tab
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear
                        )
                        .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .background(.background.secondary)
            Divider()

            // Content
            switch selectedTab {
            case .overview:
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        projectHeader
                        Divider()
                        indexCard
                        if savings.callCount > 0 {
                            Divider()
                            savingsCounter
                        }
                        Divider()
                        ragDiagram
                        if !notes.isEmpty {
                            Divider()
                            notesSection
                        }
                    }
                    .padding(24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .task {
                    savings = TokenSavingsStore.shared.savings(slug: project.slug)
                }

            case .explorer:
                RAGVisualizerView(project: project)
            }
        }
    }

    // MARK: - Project header

    private var projectHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "hexagon.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.title2)
                Text(project.name)
                    .font(.title2)
                    .fontWeight(.semibold)
            }
            Text(project.rootPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack(spacing: 12) {
                Label("\(notes.count) notes", systemImage: "doc.text")
                Label(project.slug, systemImage: "tag")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
        }
    }

    // MARK: - Index card

    private var indexCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Code Index", systemImage: "magnifyingglass.circle.fill")
                .font(.headline)

            switch indexState {
            case .notIndexed:
                HStack(spacing: 12) {
                    Image(systemName: "circle.dashed")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Not indexed yet")
                            .font(.body)
                        Text("Index once to let Claude search functions directly — 10× fewer tokens than reading files.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    reindexButton
                }

            case .indexing(let progress, let msg):
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        ProgressView(value: progress)
                        Text("\(Int(progress * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Button {
                            rag.cancelIndexing(slug: project.slug)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

            case .indexed(let files, let chunks, let date):
                HStack(spacing: 16) {
                    statBadge(value: "\(chunks)", label: "chunks", icon: "function")
                    statBadge(value: "\(files)", label: "files", icon: "doc.text.fill")
                    statBadge(
                        value: date.formatted(.relative(presentation: .named)),
                        label: "indexed",
                        icon: "clock"
                    )
                    Spacer()
                    reindexButton
                }

            case .failed(let msg):
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                    reindexButton
                }
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var reindexButton: some View {
        Button {
            rag.reindex(project: project)
        } label: {
            Label(indexState.isIndexed ? "Re-index" : "Index now", systemImage: "arrow.clockwise")
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(indexState.isIndexing)
    }

    private func statBadge(value: String, label: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
                .font(.caption)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - RAG diagram

    private var ragDiagram: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("How Claude reads your code", systemImage: "arrow.triangle.branch")
                .font(.headline)

            HStack(alignment: .top, spacing: 0) {
                // Left column: pipeline steps
                VStack(alignment: .leading, spacing: 0) {
                    ragStep(
                        icon: "doc.text.fill",
                        color: .blue,
                        title: "Source files",
                        detail: "Swift · TS · JS · Go · Rust · Python · Kotlin"
                    )
                    ragArrow
                    ragStep(
                        icon: "scissors",
                        color: .orange,
                        title: "CodeChunker",
                        detail: "Brace-counting · 200 line cap · per function/class/struct"
                    )
                    ragArrow
                    ragStep(
                        icon: "list.number",
                        color: .purple,
                        title: "BM25 Index",
                        detail: indexState.isIndexed
                            ? "\(chunkCount) chunks · camelCase tokenizer · persisted on disk"
                            : "camelCase tokenizer · persisted on disk"
                    )
                    ragArrow
                    ragStep(
                        icon: "magnifyingglass",
                        color: .green,
                        title: "search_code(\"query\")",
                        detail: "Top-K results ranked by relevance · body returned inline"
                    )
                    ragArrow
                    ragStep(
                        icon: "brain",
                        color: .accentColor,
                        title: "Claude",
                        detail: "Reads matching chunks directly · ~10× fewer tokens vs Read file"
                    )
                }

                Spacer()

                // Right column: savings callout
                if indexState.isIndexed {
                    savingsCallout
                        .padding(.leading, 16)
                }
            }
        }
    }

    private func ragStep(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.body)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private var ragArrow: some View {
        HStack {
            Spacer().frame(width: 10)
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 1, height: 14)
        }
    }

    // MARK: - Cumulative savings counter

    private var savingsCounter: some View {
        HStack(spacing: 16) {
            // Big number
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(formatTokens(savings.totalSaved))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.green)
                        .contentTransition(.numericText())
                    Text("tokens")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 2)
                }
                Text("saved vs grep + Read file")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider().frame(height: 40)

            // Call count
            VStack(alignment: .leading, spacing: 2) {
                Text("\(savings.callCount)")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                Text("search_code calls")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider().frame(height: 40)

            // Tangible metric: sessions worth of context
            let sessions = max(1, savings.totalSaved / 180_000)
            VStack(alignment: .leading, spacing: 2) {
                Text("≈ \(sessions)×")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
                Text("context windows")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 {
            let m = Double(n) / 1_000_000
            return String(format: m >= 10 ? "%.0fM" : "%.1fM", m)
        } else if n >= 1_000 {
            let k = Double(n) / 1_000
            return String(format: k >= 10 ? "%.0fK" : "%.1fK", k)
        }
        return "\(n)"
    }

    private var savingsCallout: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Token cost")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            savingsRow(label: "search_code", tokens: "~80", highlight: true)
            savingsRow(label: "grep + Read file", tokens: "~1 500", highlight: false)

            Divider()

            Text("~10–20× cheaper")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.green)

            Text("CCR auto-offloads\nchunks > 80 lines")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func savingsRow(label: String, tokens: String, highlight: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(highlight ? Color.green : Color.red.opacity(0.6))
                .frame(width: 5, height: 5)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Text(tokens)
                .font(.caption2)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(highlight ? .green : .red.opacity(0.8))
        }
    }

    // MARK: - Recent notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Notes", systemImage: "doc.text")
                .font(.headline)

            ForEach(notes.prefix(6)) { note in
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(note.title)
                        .font(.caption)
                    if !note.tags.isEmpty {
                        Text(note.tags.prefix(2).joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(note.updatedAt.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                .padding(.vertical, 2)
            }
            if notes.count > 6 {
                Text("+ \(notes.count - 6) more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private var chunkCount: Int {
        if case .indexed(_, let chunks, _) = indexState { return chunks }
        return 0
    }
}
