import SwiftUI

struct MainWindowView: View {
    @Environment(VaultManager.self) private var vault
    @Environment(MCPServer.self) private var mcp
    @Environment(CodeRAGManager.self) private var rag
    @State private var selectedProject: Project?
    @State private var selectedNote: Note?
    @State private var searchText = ""
    @State private var showingDiagnostics = false
    @State private var showingCodeIndex = false

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            ProjectListView(selectedProject: $selectedProject) { _ in
                    selectedNote = nil
                }
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
                .onChange(of: selectedProject) { selectedNote = nil }
        } content: {
            if let project = selectedProject {
                NoteListView(project: project, selectedNote: $selectedNote, searchText: searchText)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
            } else {
                emptyContent
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            }
        } detail: {
            if let project = selectedProject, let note = selectedNote {
                NoteEditorView(note: note, project: project)
                    .id(note.id)
            } else if let project = selectedProject {
                ProjectHomeView(project: project)
                    .environment(vault)
            } else {
                HomeView()
                    .environment(vault)
                    .environment(mcp)
            }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search notes")
        .navigationTitle("ContextVault")
        .toolbar {
            ToolbarItem(placement: .status) {
                Button {
                    showingCodeIndex = true
                } label: {
                    Image(systemName: "magnifyingglass.circle")
                }
                .buttonStyle(.plain)
                .help("Code Index")
            }
            ToolbarItem(placement: .status) {
                Button {
                    showingDiagnostics = true
                } label: {
                    ConnectionStatusView()
                }
                .buttonStyle(.plain)
                .help("Open diagnostics")
            }
        }
        .sheet(isPresented: $showingCodeIndex) {
            NavigationStack {
                CodeIndexView()
                    .environment(vault)
                    .environment(rag)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showingCodeIndex = false }
                        }
                    }
            }
            .frame(minWidth: 580, minHeight: 400)
        }
        .sheet(isPresented: $showingDiagnostics) {
            NavigationStack {
                DiagnosticsView()
                    .environment(mcp)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showingDiagnostics = false }
                        }
                    }
            }
            .frame(minWidth: 580, minHeight: 520)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            mcp.stop()
        }
        .task {
            mcp.start(vault: vault)
            // Load persisted code indexes in background
            for project in vault.projects {
                rag.loadIfNeeded(project: project)
            }
        }
    }

    private var emptyContent: some View {
        ContentUnavailableView {
            Label("No Project Selected", systemImage: "folder")
        } description: {
            Text("Select a project from the sidebar.")
        }
    }
}
