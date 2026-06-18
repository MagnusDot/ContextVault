import SwiftUI

struct RAGVisualizerView: View {
    let project: Project

    @State private var rawQuery = ""
    @State private var debouncedQuery = ""
    @State private var selectedFile: String? = nil
    @State private var expandedChunk: String? = nil
    @State private var showAllChunks = false

    // Chunk pools — loaded once, never recomputed in body
    @State private var topChunks: [CodeChunk] = []
    @State private var allChunks: [CodeChunk] = []
    @State private var totalCount = 0
    @State private var cachedFileStats: [(file: String, count: Int)] = []

    // Derived from pool + filter — updated via onChange, never in body
    @State private var browsedChunks: [CodeChunk] = []
    @State private var groupedChunks: [CodeChunk.ChunkType: [CodeChunk]] = [:]

    @State private var browseTypeCounts: [CodeChunk.ChunkType: Int] = [:]
    @State private var avgLineCount = 0

    @State private var searchResults: [ScoredChunk] = []
    @State private var searchTask: Task<Void, Never>? = nil

    private static let defaultLimit = 200
    // Sidebar bar width: 200pt total - 24px padding - 28px count badge - 8px spacing = 140
    private static let barMaxWidth: CGFloat = 140

    private var rag: CodeRAGManager { CodeRAGManager.shared }
    private var maxCount: Int { cachedFileStats.first?.count ?? 1 }
    private var isSearching: Bool { !debouncedQuery.isEmpty }

    var body: some View {
        Group {
            if topChunks.isEmpty {
                notIndexedPlaceholder
            } else {
                HStack(spacing: 0) {
                    fileSidebar
                    Divider()
                    VStack(spacing: 0) {
                        searchBar
                        Divider()
                        if isSearching { searchResultsList } else { chunkBrowser }
                    }
                }
            }
        }
        .task { await loadCache() }
        .onChange(of: rawQuery) { _, new in scheduleSearch(new) }
        .onChange(of: selectedFile) { updateBrowsed() }
        .onChange(of: showAllChunks) {
            if showAllChunks && allChunks.isEmpty {
                Task.detached(priority: .userInitiated) {
                    let full = rag.bm25(slug: project.slug)?.allChunks ?? []
                    await MainActor.run {
                        allChunks = full
                        updateBrowsed()
                    }
                }
            } else {
                updateBrowsed()
            }
        }
    }

    // MARK: - Cache loading (off main thread)

    private func loadCache() async {
        guard let index = rag.bm25(slug: project.slug) else { return }
        let result = await Task.detached(priority: .userInitiated) { () -> ([CodeChunk], Int, [(String, Int)]) in
            let top = index.topChunks(limit: Self.defaultLimit)
            let total = index.count
            let stats = Dictionary(grouping: index.allChunks, by: \.file)
                .map { ($0.key, $0.value.count) }
                .sorted { $0.1 > $1.1 }
            return (top, total, stats)
        }.value
        topChunks = result.0
        totalCount = result.1
        cachedFileStats = result.2
        updateBrowsed()
    }

    // MARK: - Browsed chunks update — called from onChange only

    private func updateBrowsed() {
        let pool = showAllChunks ? allChunks : topChunks
        let filtered: [CodeChunk]
        if let f = selectedFile {
            filtered = pool.filter { $0.file == f }.sorted { $0.startLine < $1.startLine }
        } else {
            filtered = pool
        }
        browsedChunks = filtered
        groupedChunks = Dictionary(grouping: filtered, by: \.type)

        browseTypeCounts = [:]
        for c in filtered { browseTypeCounts[c.type, default: 0] += 1 }
        avgLineCount = filtered.isEmpty ? 0 : filtered.reduce(0) { $0 + $1.lineCount } / filtered.count
    }

    // MARK: - Debounced search (300 ms)

    private func scheduleSearch(_ q: String) {
        searchTask?.cancel()
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            debouncedQuery = ""
            searchResults = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let results = rag.search(slug: project.slug, query: trimmed, topK: 20)
            debouncedQuery = trimmed
            searchResults = results
        }
    }

    // MARK: - Not indexed placeholder

    private var notIndexedPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass.circle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Index your code to explore it here")
                .font(.headline)
                .foregroundStyle(.secondary)
            Button("Index now") { rag.reindex(project: project) }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - File sidebar

    private var fileSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Files")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(cachedFileStats.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.background.secondary)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    FileRow(
                        name: "All files",
                        count: totalCount,
                        barWidth: Self.barMaxWidth,
                        isSelected: selectedFile == nil,
                        isAllFiles: true
                    ) { selectedFile = nil }

                    Divider().padding(.horizontal, 8).padding(.vertical, 2)

                    ForEach(cachedFileStats, id: \.file) { stat in
                        let bw = Self.barMaxWidth * CGFloat(stat.count) / CGFloat(maxCount)
                        FileRow(
                            name: fileName(stat.file),
                            count: stat.count,
                            barWidth: bw,
                            isSelected: selectedFile == stat.file,
                            isAllFiles: false
                        ) { selectedFile = selectedFile == stat.file ? nil : stat.file }
                    }
                }
                .padding(.vertical, 4)
            }

            Divider()

            VStack(spacing: 4) {
                statLine(label: "Total", value: "\(totalCount)")
                statLine(label: "Showing", value: showAllChunks ? "All" : "Top \(Self.defaultLimit)")
                statLine(label: "Files", value: "\(cachedFileStats.count)")
                statLine(label: "Avg size", value: avgLineCount > 0 ? "\(avgLineCount)L" : "—")
            }
            .padding(10)
            .background(.background.secondary)
        }
        .frame(width: 200)
    }

    private func statLine(label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().fontWeight(.medium)
        }
        .font(.caption2)
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.body)
            TextField("Search chunks… (BM25 · camelCase aware)", text: $rawQuery)
                .textFieldStyle(.plain)
                .font(.body)
            if !rawQuery.isEmpty {
                Button { rawQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                if isSearching {
                    Text("\(searchResults.count) results")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Divider().frame(height: 16)
            if !isSearching {
                Button { showAllChunks.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showAllChunks ? "square.stack.3d.up.fill" : "star.fill")
                            .font(.caption)
                        Text(showAllChunks ? "\(totalCount) chunks" : "Top \(Self.defaultLimit)")
                            .font(.caption)
                            .monospacedDigit()
                    }
                    .foregroundStyle(showAllChunks ? .secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .help(showAllChunks
                      ? "Showing all chunks — click for top concepts"
                      : "Showing top \(Self.defaultLimit) concepts by importance — click for all")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.background)
    }

    // MARK: - Search results

    private var searchResultsList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if searchResults.isEmpty {
                    Text("No results for \"\(debouncedQuery)\"")
                        .foregroundStyle(.secondary)
                        .padding(.top, 40)
                } else {
                    ForEach(searchResults, id: \.chunk.id) { scored in
                        ChunkCard(
                            chunk: scored.chunk,
                            score: scored.score,
                            isExpanded: expandedChunk == scored.chunk.id
                        ) {
                            expandedChunk = expandedChunk == scored.chunk.id ? nil : scored.chunk.id
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    // MARK: - Chunk browser (no query)

    private var chunkBrowser: some View {
        ScrollView {
            LazyVStack(spacing: 8, pinnedViews: .sectionHeaders) {
                ForEach(CodeChunk.ChunkType.allCases, id: \.self) { type_ in
                    if let chunks = groupedChunks[type_], !chunks.isEmpty {
                        Section {
                            ForEach(chunks) { chunk in
                                ChunkCard(
                                    chunk: chunk,
                                    score: nil,
                                    isExpanded: expandedChunk == chunk.id
                                ) {
                                    expandedChunk = expandedChunk == chunk.id ? nil : chunk.id
                                }
                            }
                        } header: {
                            HStack {
                                Image(systemName: type_.icon).foregroundStyle(type_.color)
                                Text("\(type_.label)  (\(chunks.count))")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.background)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    // MARK: - Helpers

    private func fileName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

// MARK: - File row

private struct FileRow: View {
    let name: String
    let count: Int
    let barWidth: CGFloat      // precomputed — no GeometryReader needed
    let isSelected: Bool
    let isAllFiles: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    // Fixed-width bar — no GeometryReader
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.secondary.opacity(0.1))
                            .frame(height: 3)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(isAllFiles ? Color.accentColor.opacity(0.5) : Color.accentColor.opacity(0.3))
                            .frame(width: max(barWidth, 1), height: 3)
                    }
                }
                Text("\(count)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Chunk card

private struct ChunkCard: View {
    let chunk: CodeChunk
    let score: Double?
    let isExpanded: Bool
    let onTap: () -> Void

    private let previewLines = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: 8) {
                    Image(systemName: chunk.type.icon)
                        .foregroundStyle(chunk.type.color)
                        .font(.caption)
                        .frame(width: 14)

                    Text(chunk.name)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .lineLimit(1)

                    Text("\(fileName(chunk.file)):\(chunk.startLine)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    if let score {
                        Text(String(format: "%.2f", score))
                            .font(.caption2)
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(scoreColor(score).opacity(0.15), in: Capsule())
                            .foregroundStyle(scoreColor(score))
                    }

                    Text("\(chunk.lineCount)L")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                codePreview
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isExpanded ? chunk.type.color.opacity(0.4) : Color.clear, lineWidth: 1)
        )
    }

    private var codePreview: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            let lines = chunk.body.components(separatedBy: "\n")
            let shown = Array(lines.prefix(previewLines))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.offset) { i, line in
                    HStack(spacing: 0) {
                        Text("\(chunk.startLine + i)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 36, alignment: .trailing)
                            .padding(.trailing, 10)
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary)
                    }
                    .padding(.vertical, 1)
                }
                if lines.count > previewLines {
                    Text("  … \(lines.count - previewLines) more lines")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 2)
                }
            }
            .padding(10)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
    }

    private func scoreColor(_ score: Double) -> Color {
        score > 3 ? .green : score > 1.5 ? .orange : .secondary
    }

    private func fileName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

// MARK: - ChunkType extensions

extension CodeChunk.ChunkType: CaseIterable {
    public static var allCases: [CodeChunk.ChunkType] {
        [.function, .class_, .struct_, .enum_, .extension_]
    }

    var icon: String {
        switch self {
        case .function:   return "function"
        case .class_:     return "building.2"
        case .struct_:    return "cube"
        case .enum_:      return "list.bullet.rectangle"
        case .extension_: return "puzzlepiece"
        }
    }

    var color: Color {
        switch self {
        case .function:   return .blue
        case .class_:     return .orange
        case .struct_:    return .purple
        case .enum_:      return .green
        case .extension_: return .teal
        }
    }

    var label: String {
        switch self {
        case .function:   return "Functions"
        case .class_:     return "Classes"
        case .struct_:    return "Structs"
        case .enum_:      return "Enums"
        case .extension_: return "Extensions"
        }
    }
}
